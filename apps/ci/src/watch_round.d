/**
One `ci test --watch` round as a task graph, run on the task executor (design
BGW15, BGW18; task-DAG TDM15, TDM16).

$(LREF planRound) turns the packages a change selected into nodes: for
`ci test`, one per leg (`-t 1`, then the parallel leg), for `ci test --build-only` one
per package, ordered after the packages it depends on. Each node runs the
command `ci test` or `ci test --build-only` would ($(REF packageTestCommands, app)), and
states its files: it reads the input sets of every package and
configuration its request's closure holds, and writes those packages'
`build` and `.dub` directories, where dub puts a path dependency's
artifacts. Two nodes whose closures share a package therefore never run at
once (TDM15), which is what keeps two dub processes off the same library.

Freshness (TDM16, BGW18) is the watch's to supply. A node's input identity
digests its command and the members of the watched input state that its
read sets and the workspace inputs hold. $(LREF RoundDriver) calls a node
fresh when it has succeeded with that identity before, in this watch, and
stale otherwise, naming a changed path its package claims: undoing an edit
returns to inputs that passed, and the node is skipped; a node that never
passed with its inputs runs every round. The record is in memory and ends
with the watch.
*/
module watch_round;

import core.time : Duration;

import sparkles.base.hash.blake3 : Blake3;
import sparkles.base.logger : error;
import sparkles.build_primitives.fileset.value : Fileset;
import sparkles.build_primitives.task.action : EnvEntry, ProcessAction, StdinPolicy;
import sparkles.build_primitives.task.executor : ExecutorOptions, RunResult, TaskContext, runGraph;
import sparkles.build_primitives.task.graph : TaskGraph, TaskGraphBuilder;
import sparkles.build_primitives.task.model;
import sparkles.build_primitives.task.process : EventChannel, MonotonicClock, ProcessDriver,
    ProcessDriverOptions;
import sparkles.build_primitives.workspace.input_state : InputState;
import sparkles.build_primitives.workspace.select : ClaimPlan, ReasonKind, Selection, SelectionReason;
import sparkles.event_horizon.sched : Sched;

import app : PackageCommand, packageBuildCommand, packageTestCommands;

/// What a round runs: `dub test` legs or `dub build`s.
enum RoundAction : ubyte
{
    test,  ///
    build, ///
}

/// How many tasks a round admits at once. Most closures share a package,
/// and their write claims serialize them whatever this says; it lets the
/// rest overlap.
enum uint roundCapacity = 2;

/// One round: its graph and, by task index, what freshness is judged by.
final class Round
{
    TaskGraph graph;  ///
    Digest[] inputs;  /// each task's input identity
    string[] changed; /// a changed path each task's package claims, or null
}

/**
The round that runs `action` over the packages `selection` holds, from
`plan` and the watched input `state`, for the repository at `repoRoot`.
`wasiCompiler` is $(REF findWasiCompiler, app)'s, for `ci test --build-only`, and
`threads` the parallel test leg's. Creates each package's `build`
directory, as `ci test` and `ci test --build-only` do.
*/
Round planRound(ClaimPlan plan, const ref Selection selection, RoundAction action,
    const ref InputState state, string repoRoot, string wasiCompiler, uint threads)
{
    import std.file : mkdirRecurse;
    import std.path : buildPath;

    auto inputs = &plan.inputs;
    // Which members each set holds, and which the workspace inputs hold:
    // one claim query per member, shared by every node.
    auto bySet = new size_t[][inputs.length];
    size_t[] workspace;
    foreach (i, ref m; state.members)
    {
        inputs.eachClaimant(m.path, (size_t k) { bySet[k] ~= i; });
        if (inputs.inWorkspace(m.path))
            workspace ~= i;
    }

    TaskGraphBuilder b;
    b.files = &inputs.sets();
    Digest[string] identity;
    string[string] changedBy;
    auto lastTask = new TaskId[selection.packages.length];
    auto planned = new bool[selection.packages.length];
    foreach (si, ref sp; selection.packages)
    {
        if (sp.platformSkipped)
            continue;
        const pkg = plan.graph.packages[sp.graphIndex];
        const request = plan.requests[sp.graphIndex];

        Fileset reads;
        bool anyReads;
        size_t[] members = workspace.dup;
        WriteClaim[] writes;
        foreach (pair; request.closure)
        {
            const k = inputs.indexOf(pair);
            if (k >= 0)
            {
                reads = anyReads ? inputs.unionInArena(reads, inputs.inputs(k)) : inputs.inputs(k);
                anyReads = true;
                members ~= bySet[k];
            }
            const dir = plan.graph.packages[pair.package_].path;
            writes ~= WriteClaim(underPackage(dir, "build"), tree: true);
            writes ~= WriteClaim(underPackage(dir, ".dub"), tree: true);
        }
        members = sortedUnique(members);
        writes = sortedUniqueClaims(writes);
        const changed = changedPathOf(sp.reasons);

        mkdirRecurse(buildPath(repoRoot, pkg.path, "build"));
        const commands = action == RoundAction.test
            ? packageTestCommands(repoRoot, pkg.path, threads)
            : [packageBuildCommand(repoRoot, pkg.path, wasiCompiler)];
        foreach (ci, ref cmd; commands)
        {
            const id = action == RoundAction.test
                ? taskId("test", pkg.shortName, ci == 0 ? "t1" : "tN").value
                : taskId("build", pkg.shortName).value;
            TaskNode node;
            node.id = id;
            node.kind = action == RoundAction.test ? TaskKind.test : TaskKind.build;
            node.label = ":" ~ pkg.shortName ~ " " ~ cmd.label;
            // Presentation by package path, then leg: `-t 1` is admitted
            // first, and the parallel leg's write claims wait for it.
            node.order = PresentationKey(0, pkg.path.length ? pkg.path : ".", cast(uint) ci);
            node.resources = ResourceClaim(1);
            node.action = TaskAction(ProcessAction(cmd.argv.dup, envOf(cmd.env), null, StdinPolicy.empty,
                Duration.zero));
            node.files = FileClaims(reads, writes);
            b.add(node);
            identity[id.text] = identityOf(state, members, cmd);
            changedBy[id.text] = changed;
            lastTask[si] = id;
        }
        planned[si] = true;
    }
    // `ci test --build-only`: a package after the packages it depends on, as dub would.
    if (action == RoundAction.build)
        foreach (e; selection.edges)
            if (planned[e.dependency] && planned[e.dependent])
                b.add(TaskEdge(lastTask[e.dependency], lastTask[e.dependent], EdgeCondition.onSuccess,
                    EdgeReason.packageDependency));

    auto built = b.build();
    if (built.hasError)
    {
        import std.conv : text;

        const why = text(built.error);
        error(i"--watch: the round's graph is invalid: $(why)");
        return null;
    }
    auto round = new Round;
    round.graph = built.value;
    foreach (ref node; round.graph.nodes)
    {
        round.inputs ~= identity[node.id.text];
        round.changed ~= changedBy[node.id.text];
    }
    return round;
}

/**
The action driver of a round: the process driver's actions, and the
watch's freshness (TDM16). `passed` maps a task id to every input identity
it succeeded with.
*/
struct RoundDriver
{
    ProcessDriver* process;           ///
    Round round;                      ///
    const(bool[Digest][string])* passed; ///

    /// Runs the task's process.
    TaskOutcome run(ref TaskContext!Sched ctx) => process.run(ctx);

    /// Fresh when the task has succeeded with these inputs before.
    Freshness freshness(ref TaskContext!Sched ctx)
    {
        const t = ctx.task.value;
        if (auto succeeded = ctx.node.id.text in *passed)
            return round.inputs[t] in *succeeded
                ? Freshness(Freshness.Kind.fresh, round.inputs[t])
                : Freshness(Freshness.Kind.stale, reason: StaleReason.inputChanged, path: round.changed[t]);
        return Freshness(Freshness.Kind.stale, reason: StaleReason.noRecord);
    }
}

/**
Runs `round` on a scheduler of its own, reporting through the TTY reporter
(plain lines without a terminal), and adds to `passed` the inputs of each
task that succeeded.
*/
RunResult runRound(Round round, ref bool[Digest][string] passed, string repoRoot, bool failFast)
{
    import sparkles.base.term_caps : detectTermCaps;
    import sparkles.build_primitives.task.reporter : consumeEvents;
    import sparkles.event_horizon.loop : LoopConfig;
    import sparkles.event_horizon.sched : SchedOptions;
    import sparkles.event_horizon.scope_ : withScope;
    import sparkles.ui.components.live : stdoutLiveRegion;
    import sparkles.ui.components.theme : makeTheme;
    import task.reporter_tty : TtyOptions, TtyReporter;

    Sched s;
    // Fibers larger than the default 64 KiB: the reporter renders on one.
    auto created = Sched.create(s, SchedOptions(stackSize: 256 * 1024), LoopConfig());
    if (created.hasError)
    {
        const why = created.error.context;
        error(i"--watch: no scheduler for the round: $(why)");
        return RunResult(exitCode: 1);
    }

    auto region = stdoutLiveRegion();
    auto reporter = TtyReporter(&region, makeTheme(detectTermCaps()), &round.graph, TtyOptions());
    auto process = ProcessDriver(ProcessDriverOptions(repoRoot: repoRoot), round.graph.nodes.length);
    auto driver = RoundDriver(&process, round, &passed);
    auto sink = new EventChannel;
    MonotonicClock clock;
    RunResult result;
    auto ran = s.run(() {
        cast(void) withScope!((ref sc) {
            sc.spawn(() { consumeEvents(s, *sink, reporter); });
            result = runGraph(s, clock, round.graph, driver, *sink,
                ExecutorOptions(capacity: roundCapacity, failFast: failFast));
            sink.close();
        })(s);
    });
    if (ran.hasError)
    {
        error(i"--watch: the round's scheduler failed");
        return RunResult(exitCode: 1);
    }
    foreach (i, outcome; result.outcomes)
        if (kindOf(outcome) == OutcomeKind.succeeded)
            passed[round.graph.nodes[i].id.text][round.inputs[i]] = true;
    return result;
}

/// `dir/leaf`, or `leaf` for the root package's empty directory.
string underPackage(string dir, string leaf) @safe pure nothrow
    => dir.length ? dir ~ "/" ~ leaf : leaf;

/// The input identity of a task: its command, and the `members` of `state`
/// (indices, sorted) that its reads and the workspace inputs hold.
Digest identityOf(const ref InputState state, scope const(size_t)[] members, const ref PackageCommand cmd)
{
    import std.algorithm.sorting : sort;

    Blake3 h;
    h.start();
    h.put(cast(const(ubyte)[]) "sparkles watch task 1\n");
    foreach (i; members)
    {
        h.put(cast(const(ubyte)[]) state.members[i].path);
        h.put(cast(ubyte) 0);
        h.put(state.members[i].id[]);
    }
    h.put(cast(ubyte) 0xff);
    foreach (a; cmd.argv)
    {
        h.put(cast(const(ubyte)[]) a);
        h.put(cast(ubyte) 0);
    }
    h.put(cast(ubyte) 0xff);
    auto names = cmd.env.keys;
    names.sort();
    foreach (n; names)
    {
        h.put(cast(const(ubyte)[]) n);
        h.put(cast(ubyte) '=');
        h.put(cast(const(ubyte)[]) cmd.env[n]);
        h.put(cast(ubyte) 0);
    }
    return h.finish();
}

// The first changed path among a selected package's reasons, or null.
private string changedPathOf(const(SelectionReason)[] reasons) @safe pure nothrow
{
    foreach (r; reasons)
        if (r.kind == ReasonKind.changed || r.kind == ReasonKind.workspaceInput)
            return r.detail;
    return null;
}

private EnvEntry[] envOf(const string[string] env)
{
    import std.algorithm.sorting : sort;

    auto names = env.keys;
    names.sort();
    EnvEntry[] entries;
    foreach (n; names)
        entries ~= EnvEntry(n, env[n]);
    return entries;
}

private size_t[] sortedUnique(size_t[] values) @safe pure nothrow
{
    import std.algorithm.iteration : uniq;
    import std.algorithm.sorting : sort;
    import std.array : array;

    values.sort();
    return values.uniq.array;
}

private WriteClaim[] sortedUniqueClaims(WriteClaim[] claims) @safe pure nothrow
{
    import std.algorithm.iteration : uniq;
    import std.algorithm.sorting : sort;
    import std.array : array;

    claims.sort!((a, b) => a.path < b.path);
    return claims.uniq!((a, b) => a.path == b.path).array;
}

@("watch_round.identityOf.followsMembersAndCommand")
@system
unittest
{
    import sparkles.build_primitives.workspace.input_state : Member;

    InputState state;
    state.members = [Member("a.d", Digest.init), Member("b.d", Digest.init)];
    state.members[1].id[0] = 1;
    auto cmd = PackageCommand("-t 1", ["dub", "test", ":a"], ["DFLAGS": "-x"]);
    const both = identityOf(state, [0, 1], cmd);
    assert(identityOf(state, [0, 1], cmd) == both, "the same inputs, the same identity");
    assert(identityOf(state, [0], cmd) != both, "a member fewer");
    state.members[1].id[0] = 2;
    assert(identityOf(state, [0, 1], cmd) != both, "a member's bytes");
    state.members[1].id[0] = 1;
    cmd.argv ~= "-v";
    assert(identityOf(state, [0, 1], cmd) != both, "the command");
}

@("watch_round.underPackage.rootPackage")
@safe pure nothrow
unittest
{
    assert(underPackage("libs/base", "build") == "libs/base/build");
    assert(underPackage("", ".dub") == ".dub");
}
