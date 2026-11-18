/**
`ci test --watch` and `ci test --build-only --watch` (design BGW13–BGW15): after
each change, the packages whose input sets the change reaches are tested
or built again, as a run of the task executor, and nothing else.

The loop derives a claim plan (`claimPlan`), materializes the union of
every package's inputs and the workspace inputs through a `WatchSession`,
which watches each directory before it lists it, and waits for a batch of
notes. A batch is never trusted on its own: the union is materialized
again, through the digest cache, and the difference of the two states is
the change, so a write that leaves a file's bytes as they were selects
nothing, and a lossy batch costs a rescan rather than a missed change. The
changed paths select packages by their claims (`selectChanged`), and the
selection becomes a round: a task graph that runs on the executor
(`watch_round`), each task fresh when it last succeeded with the same
inputs. A change to a workspace input — a recipe, a lock, the toolchain,
the planner's own sources — derives the plan again; every task's inputs
then changed, and the round runs every selected package.
*/
module watch_mode;

import core.time : Duration, msecs, seconds;

import sparkles.base.logger : error, info, warning;
import sparkles.build_primitives.resolve.platform : BuildPlatform, readCompilerIdentity;
import sparkles.build_primitives.resolve.project : RegistrySources;
import sparkles.build_primitives.task.model : Digest;
import sparkles.build_primitives.workspace.input_state : ChangeSet, InputState, difference;
import sparkles.build_primitives.workspace.package_graph : RecipeRole;
import sparkles.build_primitives.workspace.select : ClaimPlan, FocusOptions, Selection;

import watch_round : RoundAction;
import std.conv : text;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;

/// What each round runs over the packages a change selected.
alias WatchAction = RoundAction;

/// How long a batch keeps gathering notes after the last one arrived.
enum Duration quietPeriod = 200.msecs;

/// How often a degraded watch (no watcher, or one the host refused)
/// rescans instead of waiting for notes (D50).
enum Duration degradedRescan = 2.seconds;

/**
Watches the repository and runs `action` over what each change selects,
until interrupted; with `failFast`, a round stops at its first failure and
the watch ends with it.
*/
RunExpected!void runWatchMode(WatchAction action, bool failFast)
{
    import commands.files : detectRepoRoot;
    import commands.toolchain : defaultTestThreads;
    import sparkles.build_primitives.dub_manifest : hostPlatformTokens;
    import sparkles.build_primitives.resolve.configure : processEnvironment;
    import repository_inputs : repositoryFocus;

    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
    return failRun("--watch: not inside a git work tree");
    auto platform = hostBuildPlatform();
    if (platform.compiler is null)
        return failRun("no D compiler found for this host");
    const options = repositoryFocus(platform, registrySources(repoRoot), processEnvironment());
    const host = hostPlatformTokens();
    const role = action == WatchAction.test ? RecipeRole.test : RecipeRole.build;

    // Every input identity each task succeeded with, across rounds and plans.
    bool[Digest][string] passed;
    // Fixed for the watch: a test command that changed with the host's load
    // would never be fresh.
    const threads = defaultTestThreads();
    string[] pending;
    for (;;)
    {
        auto planned = planWatch(repoRoot, role, options, host);
        if (planned is null)
            return failRun("could not plan the watched packages");
        auto watch = Watch(repoRoot, planned, action, failFast, options, host, &passed, threads);
        const status = watch.run(pending);
        if (status != replanStatus)
            return status == 0 ? ranOk() : failRun(text("the watched run failed (", status, ")"), status);
        pending = watch.replanWith;
        info(i"a workspace input changed: planning again");
    }
}

private enum int replanStatus = -1;

// The claim plan, or null after reporting why there is none.
private ClaimPlan planWatch(string repoRoot, RecipeRole role, const FocusOptions options,
    scope const(string)[] host)
{
    import std.conv : text;
    import sparkles.build_primitives.workspace.select : claimPlan;

    auto planned = claimPlan(repoRoot, role, options, host);
    if (planned.hasError)
    {
        const why = text(planned.error);
        error(i"--watch: cannot plan the workspace: $(why)");
        return null;
    }
    return planned.value;
}

// The rounds of one plan.
private struct Watch
{
    string repoRoot;
    ClaimPlan plan;
    WatchAction action;
    bool failFast;
    const(FocusOptions) options;
    const(string)[] host;
    bool[Digest][string]* passed;
    uint threads;
    string[] replanWith; /// the workspace inputs that changed, when `run` returns `replanStatus`

    // Watches until a workspace input changes (`replanStatus`) or a round
    // fails under fail-fast (1). `pending` are paths a previous plan saw
    // change: their round runs as soon as this plan's inputs are read.
    int run(const(string)[] pending)
    {
        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.base.vfs.types : Rights;
        import sparkles.build_primitives.fileset.driver : InlineExecutor;
        import sparkles.build_primitives.workspace.input_state : DigestCache;
        import sparkles.build_primitives.workspace.watch : WatchSession;
        import sparkles.event_horizon.sys : BlockingVfs;

        auto vfs = new BlockingVfs;
        auto root = openRoot!(Rights.readOnly)(vfs, repoRoot, ambientAuthority());
        if (root.hasError)
        {
            error(i"--watch: cannot open $(repoRoot)");
            return 1;
        }
        auto watched = plan.inputs.unionInArena(plan.inputs.allInputs, plan.inputs.workspace);
        auto session = WatchSession.open(repoRoot);
        scope (exit)
            session.close();
        DigestCache!() cache;
        InlineExecutor exec;

        // The state the next change is measured against.
        auto first = session.materialize(root.value.borrow, plan.inputs.sets, watched, cache, exec);
        if (first.hasError)
        {
            error(i"--watch: cannot read the inputs");
            return 1;
        }
        InputState before = first.value;
        const dirs = session.watchedDirectories.length;
        if (session.degraded)
            warning(i"--watch: no file watcher on this host; rescanning every $(degradedRescan)");
        info(i"watching $(dirs) directories, $(before.members.length) files");
        if (pending.length && !round(pending, before))
            return 1;
        info(i"waiting for a change");

        for (;;)
        {
            const timeout = session.degraded ? degradedRescan : Duration.zero;
            const notes = session.nextBatch(quietPeriod, timeout);
            const heard = session.changes(notes);
            if (!heard.lossy && heard.paths.length == 0 && !session.degraded)
                continue; // nothing the inputs may hold

            auto now = session.materialize(root.value.borrow, plan.inputs.sets, watched, cache, exec);
            if (now.hasError)
            {
                // A file vanished mid-listing, or became unreadable: the next
                // batch reads it again.
                warning(i"--watch: the inputs could not be read; waiting for the next change");
                continue;
            }
            const changed = changedPaths(difference(before, now.value));
            before = now.value;
            if (changed.length == 0)
                continue; // the bytes are as they were

            foreach (path; changed)
                if (plan.inputs.inWorkspace(path))
                {
                    replanWith = changed.dup;
                    return replanStatus;
                }
            if (!round(changed, before))
                return 1;
            info(i"waiting for a change");
        }
    }

    // Selects what `changed` reaches and runs it as one executor run over
    // `state`; false when the round failed under fail-fast.
    bool round(const(string)[] changed, const ref InputState state)
    {
        import std.conv : text;
        import commands.toolchain : findWasiCompiler;
        import sparkles.build_primitives.workspace.select : selectChanged;
        import watch_round : planRound, runRound;

        auto selected = selectChanged(plan, changed, options, host);
        if (selected.hasError)
        {
            const why = text(selected.error);
            error(i"--watch: selection failed: $(why)");
            return true;
        }
        const packages = packageDirectories(plan, selected.value);
        const n = changed.length;
        if (packages.length == 0)
        {
            info(i"$(n) changed path(s) reach no package");
            return true;
        }
        string wasiCompiler;
        if (action == WatchAction.build && !findWasiCompiler(packages, wasiCompiler))
            return !failFast;
        const listed = joinNames(packages);
        info(i"$(n) changed path(s) select $(packages.length) package(s): $(listed)");
        auto r = planRound(plan, selected.value, action, state, repoRoot, wasiCompiler, threads);
        if (r is null)
            return !failFast;
        const result = runRound(r, *passed, repoRoot, failFast);
        return result.exitCode == 0 || !failFast;
    }
}


/// The repository-relative paths of a change set, in its order.
string[] changedPaths(const ChangeSet changes) @safe pure nothrow
{
    string[] paths;
    foreach (p; changes.paths)
        paths ~= p.path;
    return paths;
}

/// The directories of the packages `selection` holds that run on this
/// host, in the selection's order.
string[] packageDirectories(ClaimPlan plan, const ref Selection selection) @safe pure nothrow
{
    string[] dirs;
    foreach (p; selection.packages)
        if (!p.platformSkipped)
            dirs ~= plan.graph.packages[p.graphIndex].path;
    return dirs;
}

private string joinNames(const(string)[] names) @safe pure nothrow
{
    string s;
    foreach (i, n; names)
        s ~= (i ? ", " : "") ~ n;
    return s;
}

/**
The platform this process builds for: the host's platform and
architecture identifiers, and the compiler `$DC` names (`ldc2` when unset),
read from its `--version`. A `BuildPlatform` whose `compiler` is null,
after an error, when the compiler cannot be run or read.
*/
BuildPlatform hostBuildPlatform()
{
    import std.process : environment, execute;
    import sparkles.build_primitives.dub_manifest : hostPlatformTokens;

    BuildPlatform platform;
    platform.platform = hostPlatformTokens();
    platform.architecture = hostArchitecture();
    const binary = environment.get("DC", "ldc2");
    string output;
    try
    {
        const got = execute([binary, "--version"]);
        output = got.output;
        if (got.status != 0)
            output = null;
    }
    catch (Exception)
        output = null;
    if (output is null || !readCompilerIdentity(binary, output, platform))
    {
        error(i"--watch: cannot read the identity of the compiler $(binary) (set DC to ldc2 or dmd)");
        platform.compiler = null;
    }
    return platform;
}

/// The host's architecture identifiers, as dub names them.
string[] hostArchitecture() @safe pure nothrow
{
    version (X86_64)
        return ["x86_64"];
    else version (X86)
        return ["x86"];
    else version (AArch64)
        return ["aarch64"];
    else version (ARM)
        return ["arm"];
    else
        return null;
}

// The registry the locks pin, from `$SPARKLES_DUB_SOURCES` (the dev shell
// sets it): without it, the requests resolve no registry dependency, and
// their import paths are no package's inputs.
private RegistrySources registrySources(string repoRoot)
{
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.build_primitives.resolve.registry : nixRegistrySources, readDubLocks;
    import sparkles.build_primitives.resolve.tree : systemTree;

    const sources = environment.get("SPARKLES_DUB_SOURCES");
    if (sources is null)
    {
        warning(i"--watch: SPARKLES_DUB_SOURCES is not set; registry dependencies are left unresolved");
        return RegistrySources.init;
    }
    auto tree = systemTree();
    auto locked = readDubLocks([buildPath(repoRoot, "nix", "dub-lock.json"),
        buildPath(repoRoot, "nix", "ci-dub-lock.json")], tree);
    if (locked.hasError)
    {
        const why = locked.error;
        warning(i"--watch: cannot read the dub locks ($(why)); registry dependencies are left unresolved");
        return RegistrySources.init;
    }
    auto registry = nixRegistrySources(locked.value, sources, tree);
    if (registry.hasError)
    {
        const why = registry.error;
        warning(i"--watch: $(why); registry dependencies are left unresolved");
        return RegistrySources.init;
    }
    return registry.value;
}

@("watch_mode.changedPaths.inOrder")
@system
unittest
{
    import sparkles.build_primitives.workspace.input_state : ChangeKind, PathChange;

    ChangeSet cs;
    cs.paths = [PathChange("libs/a/src/a.d", ChangeKind.modified), PathChange("libs/b/x", ChangeKind.created)];
    assert(changedPaths(cs) == ["libs/a/src/a.d", "libs/b/x"]);
    assert(joinNames(["a", "b"]) == "a, b" && joinNames(null) == "");
}
