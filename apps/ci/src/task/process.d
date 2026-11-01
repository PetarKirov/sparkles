/++
The subprocess action adapter ([SPEC §5.1, §7, §8](../../../../docs/specs/ci/task-dag/SPEC.md)):
runs a $(REF ProcessAction, task,action) through Event Horizon's
`supervise` (event-horizon SPEC §13.5) and maps its result to a task outcome.

It reimplements none of supervision: spawn, line framing, timeout, the
process-group TERM→KILL escalation, drain, and reap are `supervise`'s. This
module only translates — argv and environment in, framed lines and samples
out as task events, the end of the run as an outcome — and keeps each task's
output in a bounded $(REF OutputSpool, task,output) that spills into the
task's sandbox directory.

Cancellation needs no code here: the executor interrupts the task's fiber,
`supervise` observes the latched interrupt, tears the process tree down, and
returns `ProcessEnd.cancelled`.

Redaction: a redacted environment value is passed to the child but never
leaves `ci` — it is masked as `<redacted>` in every output line the child
prints, before the line reaches an event or the spool.

POSIX only for now: everything below exists where Event Horizon exports
`supervise` (`processActionsAvailable`).
+/
module task.process;

/// Whether this host's Event Horizon build provides `supervise`.
enum bool processActionsAvailable = __traits(compiles, {
    import sparkles.event_horizon.supervise : supervise;
});

static if (processActionsAvailable):

import core.time : Duration, MonoTime, msecs, seconds;
import std.sumtype : match;

import sparkles.event_horizon.errors : IoError;
import sparkles.event_horizon.proc : EnvironmentChange, ExitStatus, ProcessEnd, ProcessEvent,
    ProcessEventKind, ProcessResourceUsage, ProcessStream, StdioMode, StdioSpec,
    SupervisedProcessConfig;
import sparkles.event_horizon.sched : Sched;
import sparkles.event_horizon.supervise : supervise;
import sparkles.test_runner.attributes : serial;

import task.action : InProcessAction, InertAction, ProcessAction, StdinPolicy;
import task.executor : TaskContext;
import task.model;
import task.output : OutputSpool;

/// The monotonic wall clock, as the executor's clock capability: the live
/// counterpart of `TestClock` for timestamps.
struct MonotonicClock
{
    enum string capName = "clock";

    /// Now.
    MonoTime now() const @safe nothrow @nogc => MonoTime.currTime;
}

/// Process driver settings.
struct ProcessDriverOptions
{
    /// A relative `ProcessAction.cwd` is resolved against this; a null
    /// `cwd` runs in it.
    string repoRoot;
    /// Each task's spill file is `<sandboxRoot>/<task path>/output.log`; null
    /// keeps output in memory only, dropping the oldest lines past the budget.
    string sandboxRoot;
    /// Bytes of output text a task keeps in memory.
    size_t outputMemoryBudget = 1024 * 1024;
    /// SIGTERM-to-SIGKILL grace for a timed-out or cancelled process group.
    Duration terminateGrace = 5.seconds;
    /// Resource-sample interval; zero samples only at the end.
    Duration sampleInterval = 250.msecs;
}

/// What a process task left behind, for diagnostics and summaries.
struct ProcessRecord
{
    @disable this(this);

    bool ran;                     /// the action was a process that was attempted
    ProcessEnd end;               ///
    ExitStatus status;            /// valid once a child existed and was reaped
    ProcessResourceUsage usage;   ///
    /// RSS/CPU sampling was unavailable: `Degraded(usageUnavailable)`
    /// metadata, never an outcome change ([SPEC §6.7]).
    bool usageUnavailable;
    IoError spawnError;           /// valid for `ProcessEnd.spawnFailed`
    OutputSpool output;           /// the task's lines, bounded
}

/// An in-process handler: what an `InProcessAction` names.
alias InProcessHandler = TaskOutcome delegate(ref TaskContext!Sched ctx, const ref InProcessAction action);

/**
The action driver for the live `Sched`: process actions run under
`supervise`; in-process actions dispatch to a registered handler (an unknown
handler fails the task); inert actions succeed.
*/
struct ProcessDriver
{
    @disable this();
    @disable this(this);

    /// A driver for a graph of `taskCount` tasks.
    this(ProcessDriverOptions options, size_t taskCount) @safe
    {
        this.options = options;
        records = new ProcessRecord[taskCount];
    }

    /// Registers the handler for `InProcessAction`s naming `name`.
    void register(string name, InProcessHandler handler) @safe pure nothrow
    {
        handlers[name] = handler;
    }

    /// The record of task `t`.
    ref ProcessRecord record(TaskIndex t) return @safe pure nothrow @nogc => records[t.value];

    /// Runs `ctx`'s action (the `isActionDriver` entry point).
    TaskOutcome run(ref TaskContext!Sched ctx)
    {
        return ctx.node.action.match!(
            (const ref ProcessAction p) => runProcess(ctx, p),
            (const ref InProcessAction c) {
                if (auto handler = c.handler in handlers)
                    return (*handler)(ctx, c);
                return TaskOutcome(Failed(FailureReason.contract));
            },
            (const ref InertAction _) => TaskOutcome(Succeeded()),
        );
    }

private:
    ProcessDriverOptions options;
    ProcessRecord[] records;
    InProcessHandler[string] handlers; // looked up, never iterated

    TaskOutcome runProcess(ref TaskContext!Sched ctx, const ref ProcessAction action)
    {
        import std.path : buildPath, isAbsolute;

        auto rec = &records[ctx.task.value];
        rec.ran = true;
        rec.output = OutputSpool(options.outputMemoryBudget,
            options.sandboxRoot.length ? options.sandboxRoot.buildPath(sandboxPath(ctx.node.id), "output.log")
                : null);

        SupervisedProcessConfig cfg;
        cfg.timeout = action.timeout;
        cfg.terminateGrace = options.terminateGrace;
        cfg.sampleInterval = options.sampleInterval;
        cfg.collectOutput = false; // lines arrive as events; the spool keeps them
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        final switch (action.stdin)
        {
            case StdinPolicy.empty:
                break;
        }
        const cwd = action.cwd.length == 0 ? options.repoRoot
            : action.cwd.isAbsolute || options.repoRoot.length == 0 ? action.cwd
            : options.repoRoot.buildPath(action.cwd);
        if (cwd.length)
            cfg.process.cwd = cwd;
        EnvironmentChange[] overlay;
        string[] secrets;
        foreach (entry; action.envDelta)
        {
            overlay ~= EnvironmentChange(entry.name, entry.value);
            if (entry.redacted && entry.value.length)
                secrets ~= entry.value;
        }
        cfg.process.envOverlay = overlay;

        void onEvent(in ProcessEvent ev)
        {
            final switch (ev.kind)
            {
                case ProcessEventKind.line:
                    const stream = ev.line.stream == ProcessStream.stderr_ ? OutputStream.stderr
                        : OutputStream.stdout;
                    const text = redact(cast(const(char)[]) ev.line.bytes, secrets);
                    const unterminated = !ev.line.terminated && !ev.line.truncated;
                    rec.output.append(stream, text, unterminated);
                    ctx.output(stream, text, unterminated);
                    break;
                case ProcessEventKind.sample:
                    if (ev.usage.sampled)
                        ctx.usage(ev.usage.peakRssBytes, ev.usage.userTime + ev.usage.systemTime);
                    break;
                case ProcessEventKind.exited:
                    break;
            }
        }

        auto got = supervise(*ctx.exec, action.argv, cfg, null, &onEvent);
        rec.output.flush();
        if (got.hasError)
        {
            rec.spawnError = got.error;
            rec.end = ProcessEnd.spawnFailed;
            return TaskOutcome(Failed(FailureReason.spawnFailed, got.error.code));
        }
        auto result = got.value;
        rec.end = result.end;
        rec.status = result.status;
        rec.usage = result.usage;
        rec.usageUnavailable = !result.usage.sampled;
        final switch (result.end)
        {
            case ProcessEnd.exited:
                if (result.status.ok)
                    return TaskOutcome(Succeeded());
                return TaskOutcome(result.status.signaled
                    ? Failed(FailureReason.signal, result.status.code)
                    : Failed(FailureReason.exitStatus, result.status.code));
            case ProcessEnd.timedOut:
                return TaskOutcome(Failed(FailureReason.timeout));
            case ProcessEnd.cancelled:
                return TaskOutcome(Cancelled(CancelReason.interrupted));
            case ProcessEnd.spawnFailed:
                rec.spawnError = result.spawnError;
                return TaskOutcome(Failed(FailureReason.spawnFailed, result.spawnError.code));
        }
    }
}

/**
A task's sandbox directory relative to the run's root: its id's segments as
directories (`test:sparkles.base:unittest` → `test/sparkles.base/unittest`).
A segment that is itself a path keeps its `/`s, but no component may climb:
`.` and `..` become `_`, so a sandbox never leaves its root.
*/
string sandboxPath(const TaskId id) @safe pure nothrow
{
    string path;
    size_t start;
    const text = id.text;
    foreach (i; 0 .. text.length + 1)
    {
        if (i < text.length && text[i] != ':' && text[i] != '/')
            continue;
        const component = text[start .. i];
        if (path.length)
            path ~= '/';
        path ~= component.length == 0 || component == "." || component == ".." ? "_" : component;
        start = i + 1;
    }
    return path;
}

///
@("task.process.sandboxPath.staysUnderTheRoot")
@safe pure nothrow
unittest
{
    assert(sandboxPath(taskId("test", "sparkles.base", "unittest").value) == "test/sparkles.base/unittest");
    assert(sandboxPath(taskId("docs", "verify", "docs/../x.md").value) == "docs/verify/docs/_/x.md");
    assert(sandboxPath(taskId("a", "/abs").value) == "a/_/abs");
}

/// `line` with every non-empty `secrets` value replaced by `<redacted>`.
string redact(scope const(char)[] line, scope const(string)[] secrets) @safe pure nothrow
{
    import std.array : replace;

    auto result = line.idup;
    foreach (secret; secrets)
        if (secret.length)
            result = result.replace(secret, "<redacted>");
    return result;
}

///
@("task.process.redact.masksEveryOccurrence")
@safe pure nothrow
unittest
{
    assert(redact("token=hunter2 again hunter2", ["hunter2"]) == "token=<redacted> again <redacted>");
    assert(redact("plain", ["", "x"]) == "plain");
}

// ─────────────────────────────────────────────────────────────────────────────
// Integration: real short-lived children under the executor
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import std.algorithm.searching : canFind;

    import sparkles.event_horizon.channel : Channel;
    import sparkles.event_horizon.loop : LoopConfig;
    import sparkles.event_horizon.sched : SchedOptions;
    import sparkles.event_horizon.scope_ : withScope;
    import sparkles.test_runner.skip : skipTest;

    import task.action : EnvEntry;
    import task.executor : ExecutorOptions, RunResult, runGraph;
    import task.graph : TaskGraph, TaskGraphBuilder;

    private struct LiveRun
    {
        RunResult result;
        TaskEvent[] events;
        string[][] linesOf; // by task index
        bool[] unterminatedLast;
        ProcessEnd[] ends;
        bool[] spilled;
        size_t[] spooledLines;
    }

    private TaskNode processNode(string name, string[] argv, Duration timeout = Duration.zero,
        EnvEntry[] env = null) @safe pure nothrow
        => TaskNode(taskId(name).value, TaskKind.test, name, PresentationKey(0, name),
            ResourceClaim(1), TaskAction(ProcessAction(argv, env, null, StdinPolicy.empty, timeout)));

    private LiveRun runLive(TaskNode[] nodes, TaskEdge[] edges, ExecutorOptions options,
        string sandboxRoot = null, size_t budget = 1024 * 1024) @system
    {
        TaskGraphBuilder b;
        foreach (n; nodes)
            b.add(n);
        foreach (e; edges)
            b.add(e);
        auto graph = b.build().value;

        Sched s;
        auto created = Sched.create(s, SchedOptions(), LoopConfig());
        if (created.hasError)
            skipTest("no Event Horizon backend: " ~ created.error.context);

        auto driver = ProcessDriver(ProcessDriverOptions(sandboxRoot: sandboxRoot,
            outputMemoryBudget: budget, terminateGrace: 200.msecs, sampleInterval: Duration.zero),
            graph.nodes.length);
        MonotonicClock clock;
        Channel!(TaskEvent, 16) sink;
        LiveRun run;
        auto r = s.run(() {
            cast(void) withScope!((ref sc) {
                sc.spawn(() {
                    for (;;)
                    {
                        auto e = sink.take(s);
                        if (e.hasError)
                            break;
                        run.events ~= e.value;
                    }
                });
                run.result = runGraph(s, clock, graph, driver, sink, options);
                sink.close();
            })(s);
        });
        assert(!r.hasError);
        run.linesOf = new string[][graph.nodes.length];
        run.unterminatedLast = new bool[graph.nodes.length];
        foreach (ref e; run.events)
            e.payload.match!(
                (TaskOutput o) {
                    run.linesOf[o.task.value] ~= e.text;
                    run.unterminatedLast[o.task.value] = o.unterminated;
                },
                (_) {});
        foreach (i; 0 .. graph.nodes.length)
        {
            const t = TaskIndex(cast(uint) i);
            run.ends ~= driver.record(t).end;
            run.spilled ~= driver.record(t).output.spilled;
            run.spooledLines ~= driver.record(t).output.lines;
        }
        return run;
    }

    // Whether `pid` no longer exists (allowing a reparented zombie a moment
    // to be reaped by init).
    private bool processGone(int pid) @system
    {
        import core.stdc.errno : errno, ESRCH;
        import core.sys.posix.signal : kill;
        import core.thread : Thread;

        foreach (_; 0 .. 100)
        {
            if (kill(pid, 0) != 0 && errno == ESRCH)
                return true;
            Thread.sleep(20.msecs);
        }
        return false;
    }
}

@("task.process.run.exitStatusesArgvAndFraming")
@serial
@system
unittest
{
    auto run = runLive([
        processNode("a-ok", ["sh", "-c", `printf '%s|' "$@"; printf '\n'; printf 'last'`, "sh", "a b", "", `c"d`]),
        processNode("b-exit", ["sh", "-c", "echo out; echo err >&2; exit 3"]),
        processNode("c-signal", ["sh", "-c", "kill -9 $$"]),
        processNode("d-spawn", ["/nonexistent/sparkles-ci-no-such-program"]),
    ], null, ExecutorOptions(capacity: 4));

    // Argument boundaries survive: an embedded space, an empty argument, a quote.
    assert(run.linesOf[0] == [`a b||c"d|`, "last"]);
    assert(run.unterminatedLast[0], "a final fragment without a newline is marked once");
    assert(kindOf(run.result.outcomes[0]) == OutcomeKind.succeeded);

    assert(run.result.outcomes[1] == TaskOutcome(Failed(FailureReason.exitStatus, 3)));
    assert(run.linesOf[1].length == 2);
    assert(run.result.outcomes[2] == TaskOutcome(Failed(FailureReason.signal, 9)));
    assert(kindOf(run.result.outcomes[3]) == OutcomeKind.failed);
    run.result.outcomes[3].match!((Failed f) { assert(f.reason == FailureReason.spawnFailed); }, (_) {});
    assert(run.ends[3] == ProcessEnd.spawnFailed);
    assert(run.result.exitCode == 1);
}

@("task.process.run.timeoutAndRedaction")
@serial
@system
unittest
{
    auto run = runLive([
        processNode("a-slow", ["sleep", "30"], 100.msecs),
        processNode("b-secret", ["sh", "-c", `echo "token=$GH_TOKEN"`], Duration.zero,
            [EnvEntry("GH_TOKEN", "hunter2", redacted: true), EnvEntry("PLAIN", "visible")]),
    ], null, ExecutorOptions(capacity: 2));
    assert(run.result.outcomes[0] == TaskOutcome(Failed(FailureReason.timeout)));
    assert(run.ends[0] == ProcessEnd.timedOut);
    assert(run.linesOf[1] == ["token=<redacted>"], "the child got the value; ci never shows it");
    foreach (ref e; run.events)
        assert(!e.text.canFind("hunter2"));
}

@("task.process.run.failFastTearsDownTheTree")
@serial
@system
unittest
{
    // b's shell prints its background grandchild's pid, then waits on it;
    // a's failure cancels b, whose whole process group must go.
    auto run = runLive([
        processNode("a-fail", ["sh", "-c", "sleep 0.3; exit 1"]),
        processNode("b-tree", ["sh", "-c", "sleep 30 & echo $!; wait"]),
        processNode("c-later", ["true"]),
    ], [TaskEdge(taskId("b-tree").value, taskId("c-later").value, EdgeCondition.onSuccess,
        EdgeReason.packageDependency)], ExecutorOptions(capacity: 4, failFast: true));

    import std.conv : to;

    assert(run.result.outcomes[0] == TaskOutcome(Failed(FailureReason.exitStatus, 1)));
    assert(run.result.outcomes[1] == TaskOutcome(Cancelled(CancelReason.interrupted)));
    assert(run.ends[1] == ProcessEnd.cancelled);
    assert(kindOf(run.result.outcomes[2]) == OutcomeKind.cancelled);
    assert(run.linesOf[1].length == 1);
    assert(processGone(run.linesOf[1][0].to!int), "the cancelled task's grandchild survived");
}

@("task.process.run.largeOutputSpillsToTheSandbox")
@serial
@system
unittest
{
    import std.file : exists;
    import std.path : buildPath;
    import sparkles.test_utils.tmpfs : TmpFS;

    auto tmp = TmpFS.create();
    auto run = runLive([processNode("big", ["sh", "-c", "i=0; while [ $i -lt 5000 ]; do echo line$i; i=$((i+1)); done"])],
        null, ExecutorOptions(capacity: 1), tmp.dir, 4096);
    assert(kindOf(run.result.outcomes[0]) == OutcomeKind.succeeded);
    assert(run.linesOf[0].length == 5000);
    assert(run.spilled[0] && run.spooledLines[0] == 5000);
    assert(tmp.dir.buildPath("big", "output.log").exists);
}
