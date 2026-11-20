/**
Examples on the build graph (ci task-DAG M9, CIC8): each example a
single-file package planned as an application against the variants the run
plans, its extracted source at a content-addressed path (build graph BGG4),
and each run an in-process action, `example:run`, whose output the commands
read back in presentation order.

A full-file example (`sourcePath`) is planned from its own file. A Node
module (`.mjs`) runs under `node` with nothing to build.
*/
module example_graph;

import core.time : Duration;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.conv : text;
import std.path : baseName, buildPath;

/// One example to build and, unless `buildOnly`, run.
struct ExampleJob
{
    string file;      /// the single-file package, absolute; or a `.mjs` module
    string label;     /// how reports name it
    string[] runArgs; ///
    bool buildOnly;   /// `// ci: build-only`: built, never run
}

/// What became of one example.
struct ExampleOutcome
{
    bool success;
    string output; /// the run's merged output, or the build's diagnostics
}

/**
The content-addressed path an inline example's `code` is extracted to,
beneath the worktree's `build/md-examples` (BGG4): an unchanged example keeps
its path, so its compile is reused. `name` keeps the file's module name.
*/
string extractedExamplePath(string root, string name, string code) @safe
{
    import std.digest.sha : sha256Of, toHexString;
    import std.file : exists, mkdirRecurse, readText, write;

    import std.ascii : LetterCase;

    const digest = sha256Of(code).toHexString!(LetterCase.lower)[0 .. 16].idup;
    const dir = buildPath(root, "build", "md-examples", digest);
    const file = buildPath(dir, name ~ ".d");
    if (!exists(file) || readText(file) != code)
    {
        mkdirRecurse(dir);
        write(file, code);
    }
    return file;
}

/**
Examples as part of a build graph run: the single files to plan, the run
actions to add once they are planned, and the handler that runs them. A
client puts `files` in `RunOptions.singleFiles`, calls `contribute` from its
`adjustPlan`, registers `handler` as `example:run`, and reads `outcomes`
from the finished run.
*/
final class ExamplePlan
{
    import graph_driver : GraphRun, Planned;
    import sparkles.build_primitives.task.action : InProcessAction;
    import sparkles.build_primitives.task.executor : TaskContext;
    import sparkles.build_primitives.task.model : TaskOutcome;
    import sparkles.event_horizon.sched : Sched;

    const(ExampleJob)[] jobs; ///
    Duration timeout;         ///
    private string[] runTask;
    private string[string] linkOf;
    private string[size_t] outputOf; // by job, written by the run handler

    ///
    this(const ExampleJob[] jobs, Duration timeout)
    {
        this.jobs = jobs;
        this.timeout = timeout;
        runTask = new string[jobs.length];
    }

    /// The single-file packages to plan, each once.
    string[] files() const
    {
        import std.algorithm.iteration : uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;

        string[] result;
        foreach (ref j; jobs)
            if (!j.file.endsWith(".mjs"))
                result ~= j.file;
        return result.sort.uniq.array;
    }

    /// The handler `example:run` names.
    TaskOutcome delegate(ref TaskContext!Sched, const ref InProcessAction) handler()
        => (ref TaskContext!Sched ctx, const ref InProcessAction a) => runExample(ctx, a, timeout, outputOf);

    /// Adds each example's run, after its link, to the planned graph.
    void contribute(ref Planned p)
    {
        import sparkles.build_graph.actions : Action, ActionKind;
        import sparkles.build_primitives.task.action : TaskAction;
        import sparkles.build_primitives.task.model : EdgeCondition, EdgeReason, TaskEdge, taskId;

        foreach (i, ref j; jobs)
        {
            const id = taskId("example", text(i), j.file.baseName).value;
            if (j.file.endsWith(".mjs"))
            {
                // Nothing to build: `node` runs the module.
                p.graph.actions ~= Action(ActionKind.test, id, size_t.max,
                    TaskAction(InProcessAction("example:run", [text(i), "--", "node", j.file] ~ j.runArgs.dup)), null, 1);
                runTask[i] = id.text;
                continue;
            }
            const link = j.file in p.singleFileLinks;
            if (link is null)
                continue;
            linkOf[j.file] = *link;
            if (j.buildOnly)
                continue;
            size_t variant = size_t.max;
            string binary;
            foreach (ref a; p.graph.actions)
                if (a.id.text == *link)
                {
                    // The link declares the binary it writes (BGA3).
                    variant = a.variant;
                    binary = "$IN(" ~ a.id.text ~ ")/" ~ a.outputs[0].path;
                }
            p.graph.actions ~= Action(ActionKind.test, id, variant,
                TaskAction(InProcessAction("example:run", [text(i), "--", binary] ~ j.runArgs.dup)), null, 1);
            p.graph.edges ~= TaskEdge(taskId((*link).split(":")).value, id, EdgeCondition.onSuccess,
                EdgeReason.packageDependency);
            runTask[i] = id.text;
        }
    }

    /// What became of each example in run `g`, in `jobs`' order.
    ExampleOutcome[] outcomes(ref const GraphRun g)
    {
        auto result = new ExampleOutcome[jobs.length];
        foreach (i, ref j; jobs)
        {
            if (runTask[i].length && i in outputOf)
            {
                result[i] = ExampleOutcome(g.stats.succeeded.get(runTask[i], false), outputOf[i]);
                continue;
            }
            // Not run: its build failed (or, build-only, it built). The
            // build's diagnostics are the lines its own actions wrote.
            const link = linkOf.get(j.file, null);
            // Executed or reused, the reporter says it succeeded.
            const built = link.length && g.log.lineSplitter.canFind(link ~ ": succeeded");
            string diagnostics;
            if (link.length)
            {
                size_t variant = size_t.max;
                foreach (ref a; g.plan.graph.actions)
                    if (a.id.text == link)
                        variant = a.variant;
                foreach (line; g.log.lineSplitter)
                    foreach (ref a; g.plan.graph.actions)
                        if (a.variant == variant && line.startsWith("[" ~ a.id.text ~ " "))
                            diagnostics ~= line[line.indexOf("] ") + 2 .. $] ~ "\n";
            }
            result[i] = ExampleOutcome(j.buildOnly && built, diagnostics.length ? diagnostics
                : link.length ? "" : "the example could not be planned");
        }
        return result;
    }
}

/**
Builds and runs `jobs` on the build graph beneath the store at `cache`,
`capacity` weighted units at once (CIC1), each run limited to `timeout`;
the outcomes in `jobs`' order. `error` is why the graph could not run.
*/
ExampleOutcome[] runExamplesOnGraph(string root, string cache, const ExampleJob[] jobs, uint capacity,
    Duration timeout, bool failFast, out string error)
{
    import graph_driver : Planned, runGraph, RunOptions;
    import std.datetime.systime : Clock;
    import std.process : thisProcessID;

    auto plan = new ExamplePlan(jobs, timeout);
    RunOptions o;
    o.into = buildPath(cache, "runs", text("ci-examples-", Clock.currTime.toUnixTime, "-", thisProcessID));
    o.cache = cache;
    o.singleFiles = plan.files;
    o.failFast = failFast;
    o.jobs = capacity;
    o.handlers["example:run"] = plan.handler;
    o.adjustPlan = (ref Planned p) { plan.contribute(p); };
    auto g = runGraph(root, null, o);
    if (g.error.length)
    {
        error = g.error;
        return new ExampleOutcome[jobs.length];
    }
    return plan.outcomes(g);
}

import std.array : split;
import std.string : indexOf, lineSplitter;

version (Posix):

import sparkles.build_primitives.task.action : InProcessAction;
import sparkles.build_primitives.task.executor : TaskContext;
import sparkles.build_primitives.task.model : Failed, FailureReason, OutputStream, Succeeded, TaskOutcome;
import sparkles.event_horizon.sched : Sched;

/**
`example:run`: runs the program after `--` in the worktree, its standard
error merged into its output, within `timeout`; records the output as job
`arguments[0]`'s, and succeeds when it exits zero.
*/
TaskOutcome runExample(ref TaskContext!Sched ctx, const ref InProcessAction action, Duration timeout,
    ref string[size_t] outputOf)
{
    import std.conv : to;
    import sparkles.event_horizon.proc : ProcessEvent, ProcessEventKind, StdioMode, StdioSpec,
        SupervisedProcessConfig;
    import sparkles.event_horizon.supervise : supervise;

    const job = action.arguments[0].to!size_t;
    const argv = action.arguments[2 .. $];
    SupervisedProcessConfig cfg;
    cfg.timeout = timeout;
    cfg.collectOutput = true;
    cfg.process.stderrSpec = StdioSpec(StdioMode.mergeStdout);
    // An empty, already-ended standard input: a program that would prompt
    // when it sees a terminal never does, on CI or a developer's terminal.
    cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
    cfg.sampleInterval = Duration.zero;
    void onEvent(in ProcessEvent ev)
    {
        if (ev.kind == ProcessEventKind.line)
            (() @trusted => ctx.output(OutputStream.stdout, cast(const(char)[]) ev.line.bytes))();
    }
    auto got = (() @trusted => supervise(*ctx.exec, argv, cfg, null, &onEvent))();
    if (got.hasError || got.value.spawnError.code != 0)
    {
        outputOf[job] = "cannot start " ~ argv[0];
        return TaskOutcome(Failed(FailureReason.spawnFailed));
    }
    outputOf[job] = (cast(const(char)[]) got.value.stdout_[]).idup;
    return got.value.status.ok ? TaskOutcome(Succeeded())
        : TaskOutcome(Failed(FailureReason.exitStatus, got.value.status.code));
}
