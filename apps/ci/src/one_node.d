/**
A single check as a one-node graph (ci task-DAG CIC2): `ci check …` and
`ci fix …` run their body as the one in-process action of a task graph on
the task-DAG executor, so their outcome and exit status follow the
executor's and its plain reporter's rules, as every other command's do.
The body runs on the scheduler's thread: its module state is thread-local,
and nothing else is scheduled while it blocks.
*/
module one_node;

import sparkles.build_primitives.task.model : TaskKind;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;

/**
Runs `body` as the node `<kind>:<name>` of a one-node graph and returns its
outcome: success when `body` succeeded, else a failure carrying its
message and exit status.
*/
RunExpected!void runOneNode(string name, TaskKind kind, RunExpected!void delegate() body)
{
    import std.conv : text;
    import std.stdio : stdout;
    import sparkles.build_primitives.task.action : InProcessAction, TaskAction;
    import sparkles.build_primitives.task.executor : ExecutorOptions, runGraph, TaskContext;
    import sparkles.build_primitives.task.graph : TaskGraphBuilder;
    import sparkles.build_primitives.task.model : Failed, FailurePolicy, FailureReason, OutputPolicy,
        PresentationKey, ResourceClaim, Skipped, SkipReason, Succeeded, TaskNode, TaskOutcome, taskId;
    import sparkles.build_primitives.task.process : EventChannel, MonotonicClock, ProcessDriver,
        ProcessDriverOptions;
    import sparkles.build_primitives.task.reporter : consumeEvents;
    import sparkles.build_primitives.task.reporter_plain : PlainOptions, PlainReporter;
    import sparkles.ci_provider : CiLog, systemEnvironment;
    import sparkles.event_horizon.loop : LoopConfig;
    import sparkles.event_horizon.sched : Sched, SchedOptions;
    import sparkles.event_horizon.scope_ : withScope;

    const id = taskId(text(kind), name).value;
    TaskGraphBuilder builder;
    builder.add(TaskNode(id: id, kind: kind, label: name, order: PresentationKey(0, name, 0, 0),
        resources: ResourceClaim(jobsWeight: 1), action: TaskAction(InProcessAction("one-node", [name])),
        failurePolicy: FailurePolicy.authoritative, outputPolicy: OutputPolicy.replay));
    auto built = builder.build();
    if (built.hasError)
        return failRun("cannot plan " ~ name, 2);
    auto graph = built.value;

    static struct Job
    {
        RunExpected!void delegate() body;
        RunExpected!void result;
    }
    auto job = new Job(body, ranOk());

    Sched s;
    if (Sched.create(s, SchedOptions(), LoopConfig()).hasError)
        return failRun("cannot start the executor", 2);
    auto driver = ProcessDriver(ProcessDriverOptions.init, 1);
    // The body runs on this thread, the scheduler's: its module state is
    // thread-local, and a pool's worker would see it empty. A one-node graph
    // has nothing else to schedule while it blocks.
    driver.register("one-node", (ref TaskContext!Sched ctx, const ref InProcessAction a) {
        try
            job.result = job.body();
        catch (Exception e)
            job.result = failRun(e.msg);
        // A skip is a degraded environment, which this host cannot run.
        return !job.result.hasError ? TaskOutcome(Succeeded())
            : job.result.error.skipped ? TaskOutcome(Skipped(SkipReason.platform))
            : TaskOutcome(Failed(FailureReason.exitStatus, job.result.error.exitCode));
    });
    auto writer = stdout.lockingTextWriter;
    auto reporter = PlainReporter!(typeof(writer))(&writer, &graph,
        PlainOptions(timings: true, ci: CiLog.detect(&systemEnvironment)));
    auto sink = new EventChannel;
    MonotonicClock clock;
    auto ran = s.run(() {
        cast(void) withScope!((ref sc) {
            sc.spawn(() { consumeEvents(s, *sink, reporter); });
            cast(void) runGraph(s, clock, graph, driver, *sink, ExecutorOptions(capacity: 1));
            sink.close();
        })(s);
    });
    if (ran.hasError)
        return failRun("the executor failed: " ~ text(ran.error), 2);
    return job.result;
}
