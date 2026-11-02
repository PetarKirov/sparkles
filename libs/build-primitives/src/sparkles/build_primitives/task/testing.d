/++
Test fixtures for the task DAG: a deterministic fake action driver run
under `TestSched` and `TestClock`, and helpers to build graphs and capture
a run's events.

Like `sparkles.build_primitives.testing`, it is excluded from the library
configuration and shipped by the `testing` one, so a consumer's tests (the
`ci` TTY reporter's) link it from a library built without `-unittest`.
+/
module sparkles.build_primitives.task.testing;

import core.lifetime : move;
import core.time : Duration, MonoTime;
import std.sumtype : match;

import sparkles.event_horizon.channel : Channel;
import sparkles.event_horizon.scope_ : withScope;

import sparkles.build_primitives.task.executor;
import sparkles.build_primitives.task.graph;
import sparkles.build_primitives.task.model;

import core.time : msecs;
import std.algorithm.iteration : filter, map;
import std.array : array;

import sparkles.event_horizon.clock : TestClock;
import sparkles.event_horizon.testing : advanceAndSettle, TestSched;
import sparkles.build_primitives.task.action : InertAction;

alias Clock = TestClock!(TestSched.Waker);

/// What the fake driver does for one task.
struct Script
{
    Duration duration;
    TaskOutcome outcome = TaskOutcome(Succeeded());
    /// Output lines, on stdout; a leading `!` sends the rest to stderr.
    string[] lines;
    /// Times to yield to the back of the ready queue after sleeping:
    /// reorders completions that land in one turn.
    uint yields;
    /// Report the scripted outcome even when the run asked the task to
    /// stop, as a child that finishes on its own does.
    bool ignoresCancel;
}

/// Sleeps each task's scripted duration on the virtual clock, then
/// reports its scripted outcome — or `Cancelled(interrupted)` when the
/// run asked it to stop. Records start order and peak weight.
struct FakeDriver
{
    Clock* clock;
    Script[string] scripts;
    string[] startOrder;
    uint weight, peakWeight;

    TaskOutcome run(X)(ref TaskContext!X ctx)
    {
        const id = ctx.node.id.text;
        const script = scripts.get(id, Script.init);
        startOrder ~= id;
        weight += ctx.node.resources.jobsWeight;
        if (weight > peakWeight)
            peakWeight = weight;
        scope (exit)
            weight -= ctx.node.resources.jobsWeight;
        foreach (line; script.lines)
            if (line.length && line[0] == '!')
                ctx.output(OutputStream.stderr, line[1 .. $]);
            else
                ctx.output(OutputStream.stdout, line);
        cast(void) clock.sleep(script.duration);
        foreach (_; 0 .. script.yields)
        {
            ctx.exec.wake(ctx.exec.currentContext());
            ctx.exec.park();
        }
        if (ctx.cancelRequested && !script.ignoresCancel)
            return TaskOutcome(Cancelled(CancelReason.interrupted));
        return script.outcome;
    }
}

TaskId tid(string text) @safe pure nothrow => taskId(text).value;

TaskNode tnode(string name, uint weight = 1, TaskKind kind = TaskKind.test,
    string[] keys = null, FailurePolicy policy = FailurePolicy.authoritative) @safe pure nothrow
    => TaskNode(tid(name), kind, name, PresentationKey(0, name), ResourceClaim(weight, 0, keys),
        TaskAction(InertAction(name)), policy);

TaskEdge tedge(string from, string to, EdgeCondition c = EdgeCondition.onSuccess) @safe pure nothrow
    => TaskEdge(tid(from), tid(to), c, EdgeReason.packageDependency);

TaskGraph graphOf(TaskNode[] nodes, TaskEdge[] edges) @safe pure nothrow
{
    TaskGraphBuilder b;
    foreach (n; nodes)
        b.add(n);
    foreach (e; edges)
        b.add(e);
    return b.build().value;
}

struct Run
{
    RunResult result;
    TaskEvent[] events;
    string[] startOrder;
    uint peakWeight;
    MonoTime[string] startedAt, finishedAt;

    string outcomeOf(const ref TaskGraph g, string name) @safe
    {
        import std.conv : text;

        return text(kindOf(result.outcomes[g.indexOf(tid(name)).value]));
    }

}

size_t countOf(alias pred)(const(TaskEvent)[] events)
    => events.filter!(e => e.payload.match!(pred, _ => false)).array.length;

// `cancelAt`: when set, an outside fiber calls `cancel(cancelCause)` at
// that virtual time.
Run runFake(const ref TaskGraph g, Script[string] scripts, ExecutorOptions options,
    Duration cancelAt = Duration.zero, CancelCause cancelCause = CancelCause.interrupt) @system
{
    TestSched sched;
    auto clock = Clock(sched.waker());
    auto driver = FakeDriver(&clock, scripts);
    Channel!(TaskEvent, 4) sink; // small: the executor parks on backpressure
    Run run;
    sched.run(() {
        cast(void) withScope!((ref sc) {
            sc.spawn(() {
                for (;;)
                {
                    auto e = sink.take(sched);
                    if (e.hasError)
                        break;
                    e.value.payload.match!(
                        (TaskStarted s) { run.startedAt[g[s.task].id.text] = e.value.at; },
                        (TaskFinished f) { run.finishedAt[g[f.task].id.text] = e.value.at; },
                        (_) {});
                    run.events ~= e.value;
                }
            });
            auto executor = TaskExecutor!(TestSched, Clock, FakeDriver, Channel!(TaskEvent, 4))(
                &sched, &clock, &g, &driver, &sink, options);
            if (cancelAt > Duration.zero)
                sc.spawn(() {
                    cast(void) clock.sleep(cancelAt);
                    executor.cancel(cancelCause);
                });
            run.result = executor.run();
            sink.close();
        })(sched);
    });
    advanceAndSettle(sched, clock);
    assert(sched.liveFibers == 0, "the run left a fiber behind");
    run.startOrder = driver.startOrder;
    run.peakWeight = driver.peakWeight;
    return run;
}

// Every permutation of `items`, in lexicographic order of positions.
T[][] permutations(T)(T[] items) @safe pure nothrow
{
    if (items.length <= 1)
        return [items.dup];
    T[][] all;
    foreach (i; 0 .. items.length)
        foreach (rest; permutations(items[0 .. i] ~ items[i + 1 .. $]))
            all ~= [items[i]] ~ rest;
    return all;
}
