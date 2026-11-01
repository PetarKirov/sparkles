/++
The task executor ([SPEC §5, §7–§9](../../../../../../docs/specs/ci/task-dag/SPEC.md)):
weighted admission with exclusive keys, conditional edge resolution, outcomes,
the event stream, structured fail-fast, external cancellation, and protected
cleanup.

The executor knows actions only through an $(I action driver), and events
only through an $(I event sink). It is generic over the Event Horizon fiber
executor `X` and clock `C`, so the same code runs on the live `Sched` inside
a `LoopGroup` and on `TestSched` under a `TestClock`:

$(LIST
    * A driver `D` provides `TaskOutcome run(ref TaskContext!X)`, called on the
        task's own fiber ($(LREF isActionDriver)).
    * A sink `S` provides `put(ref X, TaskEvent)` returning an `IoResult`:
        the intra-worker `Channel`, or the cross-worker channel once the
        reporter runs elsewhere ($(LREF isEventSink)). The executor is its only
        producer; it never closes it.
)

Admission ([SPEC §5.3, §9]): ready tasks are considered in presentation
order — the graph's index order, by `PresentationKey` then `TaskId`. A task
starts when its exclusive keys are free and its weight, clamped to the
capacity, fits. A ready task that waits for $(I capacity) stops admission of
every later task until it starts — no backfilling past it — so a heavy task
cannot be starved by a stream of light ones. A task that waits only for a
key does not hold back the rest.

Fail-fast ([SPEC §8]): the first authoritative failure — the lowest index
among those that complete in the same turn — emits `CancellationRequested`
once, closes admission, and interrupts every running task except cleanup.
A task decided after admission closed becomes `Blocked` when its block
descends from a failure, otherwise `Cancelled(notAdmitted)`. Cleanup tasks
(`TaskKind.cleanup`) still start once ready and run under `protect`. A
provisional failure never triggers fail-fast.

A task the executor interrupted that then reports `Failed` is recorded as
`Cancelled(interrupted)`: a child killed because the run was cancelled adds
no failure of its own.
+/
module sparkles.build_primitives.task.executor;

import core.lifetime : move;
import core.stdc.errno : ECANCELED;
import core.time : Duration, MonoTime;
import std.sumtype : match;

import sparkles.event_horizon.cause : FiberContext, Interrupt, InterruptKind, interruptFiber,
    interruptRequested;
import sparkles.event_horizon.channel : Channel;
import sparkles.event_horizon.capability : isFiberExecutor;
import sparkles.event_horizon.scope_ : OnChildFailure, protect, ScopeOptions, withScope;

import sparkles.build_primitives.task.graph;
import sparkles.build_primitives.task.model;

/// Whether `D` can run a task's action on executor `X`.
enum bool isActionDriver(D, X) = __traits(compiles, (ref D d, ref TaskContext!X ctx) {
    TaskOutcome outcome = d.run(ctx);
});

/// Whether `S` accepts the executor's events on executor `X`: the shape of
/// `Channel.put` and of the cross-worker channel.
enum bool isEventSink(S, X) = __traits(compiles, (ref S s, ref X x, TaskEvent e) {
    auto r = s.put(x, move(e));
    bool failed = r.hasError;
});

/// What a driver sees of the task it runs.
struct TaskContext(X)
{
    X* exec;                 /// the executor the task's fiber runs on
    TaskIndex task;          ///
    const(TaskNode)* node;   ///

    private void delegate(TaskIndex, OutputStream, scope const(char)[], bool) outputFn;
    private void delegate(TaskIndex, ulong, Duration) usageFn;

    /// Reports one assembled output line (without its terminator); the
    /// executor numbers it and forwards it as a `TaskOutput` event.
    void output(OutputStream stream, scope const(char)[] line, bool unterminated = false)
        => outputFn(task, stream, line, unterminated);

    /// Reports a resource-usage sample.
    void usage(ulong rssBytes, Duration cpu) => usageFn(task, rssBytes, cpu);

    /// Whether the run asked this task to stop: a cancellation checkpoint
    /// for in-process actions.
    bool cancelRequested() => interruptRequested(*exec.currentContext());
}

/// Executor settings.
struct ExecutorOptions
{
    /// Total weighted capacity (`--jobs`); at least 1.
    uint capacity = 1;
    /// Stop admission and cancel on the first authoritative failure.
    bool failFast;
}

/// What a run produced.
struct RunResult
{
    /// One terminal outcome per task, by index.
    TaskOutcome[] outcomes;
    /// The primary cause: the triggering failure under fail-fast, else the
    /// lowest-index task whose outcome fails the command. Invalid when none.
    TaskIndex primaryFailure;
    /// Why the run was cancelled, when it was.
    bool cancelled;
    CancelCause cancelCause; /// meaningful when `cancelled`
    /// `0` success, `1` failure, `130` SIGINT, `143` SIGTERM ([SPEC §8]).
    int exitCode;
}

/**
Runs `graph` to completion on `exec` and returns every task's outcome.
Must be called from a fiber of `exec`. Events go to `sink`; the caller closes
it afterwards so the reporter drains and ends.
*/
RunResult runGraph(X, C, D, S)(ref X exec, ref C clock, const ref TaskGraph graph, ref D driver,
    ref S sink, ExecutorOptions options)
if (isFiberExecutor!X && isActionDriver!(D, X) && isEventSink!(S, X))
{
    auto executor = TaskExecutor!(X, C, D, S)(&exec, &clock, &graph, &driver, &sink, options);
    return executor.run();
}

/**
The executor's state for one run: address-pinned, so it can hand its own
methods to task fibers as delegates. $(LREF runGraph) is the usual entry;
hold an instance to call $(LREF cancel) from another fiber (a signal
watcher).
*/
struct TaskExecutor(X, C, D, S)
{
    @disable this();
    @disable this(this);

    /// Prepares a run; nothing starts until $(LREF run).
    this(X* exec, C* clock, const(TaskGraph)* graph, D* driver, S* sink, ExecutorOptions options)
    in (options.capacity > 0, "--jobs must be positive")
    {
        this.exec = exec;
        this.clock = clock;
        this.graph = graph;
        this.driver = driver;
        this.sink = sink;
        this.options = options;
        const n = graph.nodes.length;
        outcomes = new OutcomeSlot[n];
        state = new TaskState[n];
        fibers = new FiberContext*[n];
        interrupted = new bool[n];
        streamSeq = new ulong[2 * n];
        chunkSeq = new ulong[n];
        started = new MonoTime[n];
    }

    /**
    Requests external cancellation ([SPEC §8]): emits `CancellationRequested`
    with `cause` (unless the run is already cancelling), closes admission,
    and interrupts running tasks. Callable from any fiber of the executor.
    */
    void cancel(CancelCause cause)
    {
        if (cancelling)
            return;
        externalCause = cause;
        externalRequested = true;
        // Wake the scheduler if it is parked; a full channel means it is
        // not, and it checks the flag on its next turn.
        cast(void) completions.tryPut(Completion(TaskIndex.init));
    }

    /// Runs the graph; see $(LREF runGraph).
    RunResult run()
    {
        emit(TaskEventPayload(GraphPlanned(graph.nodes.length, graph.edges.length, options.capacity)));
        free = options.capacity;

        auto scoped = withScope!((ref sc) {
            for (;;)
            {
                if (externalRequested && !cancelling)
                    requestCancellation(externalCause, TaskIndex.init);
                resolve();
                admit((TaskIndex t) { cast(void) sc.spawn(() { runTask(t); }); });
                if (running == 0)
                    break;
                // One completion parks; the rest of this turn's are drained
                // without parking, so simultaneous failures are compared.
                auto first = completions.take(*exec);
                if (first.hasError)
                {
                    // The scheduler fiber itself was interrupted (an outer
                    // shutdown): cancel the run, then keep collecting under
                    // protection so every child is accounted for.
                    if (!cancelling)
                        requestCancellation(CancelCause.terminate, TaskIndex.init);
                    protect!(() { drainProtected(); })(*exec);
                    break;
                }
                Completion[] batch = [move(first.value)];
                Completion more;
                while (completions.tryTake(more))
                    batch ~= more;
                finishBatch(batch);
            }
        })(*exec, ScopeOptions(onFailure: OnChildFailure.collect));

        RunResult result;
        result.outcomes = new TaskOutcome[outcomes.length];
        foreach (i, slot; outcomes)
        {
            assert(!slot.isNull, "the run ended with an undecided task");
            result.outcomes[i] = slot.get;
        }
        result.cancelled = cancelling;
        result.cancelCause = cancelCause;
        result.primaryFailure = primaryCause;
        if (!result.primaryFailure.valid)
            foreach (i, ref outcome; result.outcomes)
                if (failsCommand(outcome)
                    && graph.nodes[i].failurePolicy == FailurePolicy.authoritative)
                {
                    result.primaryFailure = TaskIndex(cast(uint) i);
                    break;
                }
        if (cancelling && cancelCause == CancelCause.interrupt)
            result.exitCode = 130;
        else if (cancelling && cancelCause == CancelCause.terminate)
            result.exitCode = 143;
        else
            result.exitCode = result.primaryFailure.valid || scoped.hasError ? 1 : 0;
        emit(TaskEventPayload(RunFinished(result.exitCode)));
        return result;
    }

private:
    enum TaskState : ubyte { pending, ready, running, done }

    static struct Completion
    {
        TaskIndex task; // invalid: a wake-up, not a completion
        TaskOutcome outcome;
    }

    X* exec;
    C* clock;
    const(TaskGraph)* graph;
    D* driver;
    S* sink;
    ExecutorOptions options;

    Channel!(Completion, 64) completions;
    OutcomeSlot[] outcomes;
    TaskState[] state;
    FiberContext*[] fibers;
    bool[] interrupted;
    ulong[] streamSeq; // 2 per task: stdout, stderr
    ulong[] chunkSeq;
    MonoTime[] started;
    bool[string] heldKeys; // membership only; never iterated
    uint free;
    size_t running;
    ulong sequence;
    bool sinkGone;

    bool cancelling;
    CancelCause cancelCause;
    TaskIndex primaryCause;
    bool externalRequested;
    CancelCause externalCause;

    void emit(TaskEventPayload payload, string text = null)
    {
        if (sinkGone)
            return;
        auto event = TaskEvent(sequence++, clock.now(), payload, text);
        // A sink that is closed or whose put was interrupted stops
        // receiving; the run itself carries on.
        if (sink.put(*exec, move(event)).hasError)
            sinkGone = true;
    }

    void finish(TaskIndex t, TaskOutcome outcome, Duration elapsed = Duration.zero)
    {
        outcomes[t.value] = outcome;
        state[t.value] = TaskState.done;
        emit(TaskEventPayload(TaskFinished(t, outcome, elapsed)));
    }

    bool isCleanup(TaskIndex t) const @safe pure nothrow @nogc
        => (*graph)[t].kind == TaskKind.cleanup;

    // Decides every pending task whose prerequisites are terminal, in
    // topological order, so a decision cascades within one pass.
    void resolve()
    {
        foreach (t; graph.topologicalOrder)
        {
            if (state[t.value] != TaskState.pending)
                continue;
            const r = readiness(*graph, t, outcomes);
            final switch (r.kind)
            {
                case ReadinessKind.waiting:
                    break;
                case ReadinessKind.blocked:
                    if (cancelling && !r.blocked.fromFailure && !isCleanup(t))
                        finish(t, TaskOutcome(Cancelled(CancelReason.notAdmitted)));
                    else
                        finish(t, TaskOutcome(r.blocked));
                    break;
                case ReadinessKind.ready:
                    if (cancelling && !isCleanup(t))
                    {
                        finish(t, TaskOutcome(Cancelled(CancelReason.notAdmitted)));
                        break;
                    }
                    state[t.value] = TaskState.ready;
                    emit(TaskEventPayload(TaskReady(t)));
                    break;
            }
        }
    }

    // Starts ready tasks in index (presentation) order.
    void admit(scope void delegate(TaskIndex) spawn)
    {
        foreach (i; 0 .. cast(uint) state.length)
        {
            if (state[i] != TaskState.ready)
                continue;
            const t = TaskIndex(i);
            if (cancelling && !isCleanup(t))
            {
                finish(t, TaskOutcome(Cancelled(CancelReason.notAdmitted)));
                continue;
            }
            const claim = (*graph)[t].resources;
            bool keyBusy;
            foreach (key; claim.exclusiveKeys)
                if (key in heldKeys)
                    keyBusy = true;
            if (keyBusy)
                continue;
            const weight = claim.admittedWeight(options.capacity);
            if (weight > free)
                break; // no backfilling past a task waiting for capacity
            free -= weight;
            foreach (key; claim.exclusiveKeys)
                heldKeys[key] = true;
            state[i] = TaskState.running;
            ++running;
            started[i] = clock.now();
            emit(TaskEventPayload(TaskStarted(t)));
            spawn(t);
        }
    }

    // The body of a task's fiber.
    void runTask(TaskIndex t)
    {
        fibers[t.value] = exec.currentContext();
        TaskOutcome outcome;
        scope (exit)
        {
            fibers[t.value] = null;
            cast(void) protect!(() => completions.put(*exec, Completion(t, outcome)))(*exec);
        }
        auto ctx = TaskContext!X(exec, t, &(*graph)[t], &onOutput, &onUsage);
        if (isCleanup(t))
            outcome = protect!(() => driveCatching(ctx))(*exec);
        else if (cancelling)
            outcome = TaskOutcome(Cancelled(CancelReason.interrupted));
        else
            outcome = driveCatching(ctx);
    }

    TaskOutcome driveCatching(ref TaskContext!X ctx)
    {
        try
            return driver.run(ctx);
        catch (Exception)
            return TaskOutcome(Failed(FailureReason.contract));
    }

    void onOutput(TaskIndex t, OutputStream stream, scope const(char)[] line, bool unterminated)
    {
        auto seq = &streamSeq[2 * t.value + stream];
        emit(TaskEventPayload(TaskOutput(t, stream, (*seq)++, chunkSeq[t.value]++, unterminated)),
            line.idup);
    }

    void onUsage(TaskIndex t, ulong rss, Duration cpu)
    {
        emit(TaskEventPayload(TaskUsage(t, rss, cpu)));
    }

    void finishBatch(Completion[] batch)
    {
        TaskIndex firstFailure;
        foreach (ref c; batch)
        {
            if (!c.task.valid)
                continue; // a cancellation wake-up
            const i = c.task.value;
            auto outcome = c.outcome;
            if (interrupted[i] && kindOf(outcome) == OutcomeKind.failed)
                outcome = TaskOutcome(Cancelled(CancelReason.interrupted));
            const claim = (*graph)[c.task].resources;
            free += claim.admittedWeight(options.capacity);
            foreach (key; claim.exclusiveKeys)
                heldKeys.remove(key);
            --running;
            finish(c.task, outcome, clock.now() - started[i]);
            if (kindOf(outcome) == OutcomeKind.failed
                && (*graph)[c.task].failurePolicy == FailurePolicy.authoritative
                && (!firstFailure.valid || c.task < firstFailure))
                firstFailure = c.task;
        }
        if (firstFailure.valid && !primaryCause.valid)
            primaryCause = firstFailure;
        if (options.failFast && firstFailure.valid && !cancelling)
            requestCancellation(CancelCause.failFast, firstFailure);
    }

    void requestCancellation(CancelCause cause, TaskIndex causal)
    {
        cancelling = true;
        cancelCause = cause;
        emit(TaskEventPayload(CancellationRequested(cause, causal)));
        foreach (i, f; fibers)
            if (f !is null && state[i] == TaskState.running && !isCleanup(TaskIndex(cast(uint) i)))
            {
                interrupted[i] = true;
                interruptFiber(f, Interrupt(cause == CancelCause.failFast
                    ? InterruptKind.cancelled : InterruptKind.shutdown));
            }
        // Running tasks that have not reached their fiber yet see
        // `cancelling` when they do, and so does every later decision.
        foreach (i, s; state)
            if (s == TaskState.running && fibers[i] is null)
                interrupted[i] = true;
    }

    // After the scheduler itself was interrupted: collect every running
    // task's completion, and decide the rest.
    void drainProtected()
    {
        while (running > 0)
        {
            auto c = completions.take(*exec);
            if (c.hasError)
                break;
            finishBatch([move(c.value)]);
        }
        resolve();
        foreach (i, s; state)
            if (s == TaskState.ready || s == TaskState.pending)
                finish(TaskIndex(cast(uint) i), TaskOutcome(Cancelled(CancelReason.notAdmitted)));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests: a deterministic fake driver under TestSched and TestClock
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import core.time : msecs;
    import std.algorithm.iteration : filter, map;
    import std.array : array;

    import sparkles.build_primitives.task.testing;
}

@("build_primitives.task.executor.run.eventsAreSequencedAndMonotonic")
@system
unittest
{
    const g = graphOf([tnode("a"), tnode("b")], [tedge("a", "b")]);
    auto run = runFake(g, ["a": Script(5.msecs, lines: ["one", "two"]), "b": Script(3.msecs)],
        ExecutorOptions(capacity: 2));
    assert(run.result.exitCode == 0);
    foreach (i, e; run.events)
    {
        assert(e.sequence == i, "sequence numbers are dense from 0");
        if (i)
            assert(e.at >= run.events[i - 1].at, "timestamps are monotonic");
    }
    assert(run.events[0].payload.match!((GraphPlanned p) => p.nodes == 2 && p.capacity == 2, _ => false));
    assert(run.events[$ - 1].payload.match!((RunFinished f) => f.exitCode == 0, _ => false));
    const lines = run.events.filter!(e => e.payload.match!((TaskOutput o) => true, _ => false))
        .map!(e => e.text).array;
    assert(lines == ["one", "two"]);
    assert(run.startedAt["b"] - MonoTime.zero == 5.msecs, "b waits for a");
    assert(run.finishedAt["b"] - MonoTime.zero == 8.msecs);
}

@("build_primitives.task.executor.admission.capacityAndPresentationOrder")
@system
unittest
{
    // Inserted out of order; presentation order is by name.
    auto nodes = [tnode("e", 2), tnode("b", 2), tnode("f", 2), tnode("a", 2), tnode("d", 2), tnode("c", 2)];
    const g = graphOf(nodes, null);
    Script[string] scripts;
    foreach (n; nodes)
        scripts[n.id.text] = Script(10.msecs);

    auto wide = runFake(g, scripts, ExecutorOptions(capacity: 4));
    assert(wide.peakWeight == 4, "capacity bounds the running weight");
    assert(wide.startOrder == ["a", "b", "c", "d", "e", "f"]);
    assert(wide.finishedAt["f"] - MonoTime.zero == 30.msecs, "three waves of two");

    auto serial = runFake(g, scripts, ExecutorOptions(capacity: 1));
    assert(serial.peakWeight == 2, "a claim over capacity runs alone, clamped");
    assert(serial.startOrder == ["a", "b", "c", "d", "e", "f"]);
}

@("build_primitives.task.executor.admission.noStarvationOfAHeavyTask")
@system
unittest
{
    // `a` holds half the capacity; `b` needs all of it; the light tasks
    // after `b` would fit beside `a` but must not overtake `b`.
    const g = graphOf([tnode("a", 2), tnode("b", 4), tnode("c"), tnode("d"), tnode("e")], null);
    auto run = runFake(g, ["a": Script(10.msecs), "b": Script(5.msecs), "c": Script(1.msecs),
        "d": Script(1.msecs), "e": Script(1.msecs)], ExecutorOptions(capacity: 4));
    assert(run.startOrder == ["a", "b", "c", "d", "e"]);
    assert(run.startedAt["b"] - MonoTime.zero == 10.msecs);
    assert(run.startedAt["c"] - MonoTime.zero == 15.msecs);
}

@("build_primitives.task.executor.admission.overCapacityClaimRunsAlone")
@system
unittest
{
    const g = graphOf([tnode("a", 8), tnode("b"), tnode("c")], null);
    auto run = runFake(g, ["a": Script(10.msecs), "b": Script(4.msecs), "c": Script(4.msecs)],
        ExecutorOptions(capacity: 3));
    assert(run.result.exitCode == 0);
    assert(run.startedAt["b"] - MonoTime.zero == 10.msecs, "nothing runs beside a clamped claim");
    assert(run.startedAt["c"] - MonoTime.zero == 10.msecs);
}

@("build_primitives.task.executor.admission.exclusiveKeysSerializeOnlyTheirHolders")
@system
unittest
{
    const g = graphOf([tnode("a", 1, TaskKind.rewrite, ["workspace-write:README.md"]),
        tnode("b", 1, TaskKind.rewrite, ["workspace-write:README.md"]), tnode("c")], null);
    auto run = runFake(g, ["a": Script(10.msecs), "b": Script(10.msecs), "c": Script(1.msecs)],
        ExecutorOptions(capacity: 8));
    assert(run.startedAt["b"] - MonoTime.zero == 10.msecs, "b waits for a's key");
    assert(run.startedAt["c"] - MonoTime.zero == 0.msecs, "a key wait holds back nothing else");
}

@("build_primitives.task.executor.failFast.simultaneousFailuresPickTheLowestKey")
@system
unittest
{
    // a, b and c all fail at t=5, and their completions reach the
    // scheduler in one turn as c, a, b; d is still running and e has not
    // started.
    foreach (order; permutations(["a", "b", "c"]))
    {
        TaskNode[] nodes;
        foreach (name; order)
            nodes ~= tnode(name);
        nodes ~= [tnode("d"), tnode("e")];
        const g = graphOf(nodes, [tedge("d", "e")]);
        Script[string] scripts = ["d": Script(20.msecs), "e": Script(1.msecs)];
        foreach (name; order)
            scripts[name] = Script(5.msecs, TaskOutcome(Failed(FailureReason.exitStatus, 1)),
                yields: name == "c" ? 0 : 1);

        auto run = runFake(g, scripts, ExecutorOptions(capacity: 8, failFast: true));
        assert(run.result.exitCode == 1);
        assert(g[run.result.primaryFailure].id.text == "a");
        assert(countOf!((CancellationRequested c) => c.cause == CancelCause.failFast
            && g[c.causalTask].id.text == "a")(run.events) == 1);
        assert(countOf!((CancellationRequested _) => true)(run.events) == 1, "exactly once");
        assert(run.outcomeOf(g, "d") == "cancelled");
        assert(run.outcomeOf(g, "e") == "cancelled");
        assert("e" !in run.startedAt, "no admission after cancellation");
    }
}

@("build_primitives.task.executor.failFast.blockedCancelledAndCleanup")
@system
unittest
{
    // a fails -> b, c blocked (from failure); d running -> interrupted; e
    // waits on d -> not admitted; cleanup runs always, protected.
    const g = graphOf([tnode("a"), tnode("b"), tnode("c"), tnode("d"), tnode("e"),
        tnode("z", 1, TaskKind.cleanup)], [tedge("a", "b"), tedge("b", "c"), tedge("d", "e"),
        tedge("c", "z", EdgeCondition.always), tedge("e", "z", EdgeCondition.always)]);
    Script[string] scripts = ["a": Script(5.msecs, TaskOutcome(Failed(FailureReason.exitStatus, 2))),
        "d": Script(20.msecs), "z": Script(3.msecs)];

    // Completion orders scrambled through the durations.
    foreach (dDuration; [2.msecs, 20.msecs])
    {
        scripts["d"] = Script(dDuration);
        auto run = runFake(g, scripts, ExecutorOptions(capacity: 8, failFast: true));
        assert(run.result.exitCode == 1);
        assert(run.outcomeOf(g, "b") == "blocked");
        assert(failsCommand(run.result.outcomes[g.indexOf(tid("c")).value]), "blocked from failure");
        assert(run.outcomeOf(g, "z") == "succeeded", "cleanup still runs");
        if (dDuration == 20.msecs)
        {
            assert(run.outcomeOf(g, "d") == "cancelled");
            assert(run.outcomeOf(g, "e") == "cancelled");
            assert("e" !in run.startedAt);
        }
        else
            assert(run.outcomeOf(g, "e") == "succeeded", "work finished before the failure stands");
    }

    // Without fail-fast, independent work runs on.
    auto patient = runFake(g, scripts, ExecutorOptions(capacity: 8));
    assert(patient.outcomeOf(g, "e") == "succeeded");
    assert(patient.outcomeOf(g, "b") == "blocked");
    assert(countOf!((CancellationRequested _) => true)(patient.events) == 0);
}

@("build_primitives.task.executor.failFast.provisionalFailureFallsBackWithoutCancelling")
@system
unittest
{
    // coverage (provisional) fails -> plain retry runs -> classify.
    const g = graphOf([tnode("cov", 2, TaskKind.test, null, FailurePolicy.provisional),
        tnode("plain", 2), tnode("classify", 1, TaskKind.classify), tnode("other")],
        [tedge("cov", "plain", EdgeCondition.onFailure),
        tedge("cov", "classify", EdgeCondition.onCompletion),
        tedge("plain", "classify", EdgeCondition.onCompletion)]);
    auto run = runFake(g, ["cov": Script(5.msecs, TaskOutcome(Failed(FailureReason.exitStatus, 1))),
        "plain": Script(5.msecs), "other": Script(30.msecs)], ExecutorOptions(capacity: 8, failFast: true));
    assert(countOf!((CancellationRequested _) => true)(run.events) == 0, "a provisional failure is no trigger");
    assert(run.outcomeOf(g, "plain") == "succeeded");
    assert(run.outcomeOf(g, "classify") == "succeeded");
    assert(run.outcomeOf(g, "other") == "succeeded");
    assert(run.result.exitCode == 0);

    // A coverage success makes the fallback's condition impossible: blocked,
    // and no failure.
    auto clean = runFake(g, ["cov": Script(5.msecs)], ExecutorOptions(capacity: 8, failFast: true));
    assert(clean.outcomeOf(g, "plain") == "blocked");
    assert(clean.result.exitCode == 0);
}

@("build_primitives.task.executor.cancel.externalInterrupt")
@system
unittest
{
    const g = graphOf([tnode("a"), tnode("b"), tnode("c", 1, TaskKind.cleanup)],
        [tedge("a", "b"), tedge("b", "c", EdgeCondition.always)]);
    auto run = runFake(g, ["a": Script(10.msecs), "c": Script(1.msecs)], ExecutorOptions(capacity: 4),
        5.msecs, CancelCause.interrupt);
    assert(run.result.cancelled && run.result.cancelCause == CancelCause.interrupt);
    assert(run.result.exitCode == 130);
    assert(run.outcomeOf(g, "a") == "cancelled");
    assert(run.outcomeOf(g, "b") == "cancelled", "not admitted, and no failure");
    assert(run.outcomeOf(g, "c") == "succeeded");
    assert(countOf!((CancellationRequested c) => c.cause == CancelCause.interrupt
        && !c.causalTask.valid)(run.events) == 1);

    auto terminated = runFake(g, ["a": Script(10.msecs)], ExecutorOptions(capacity: 4),
        5.msecs, CancelCause.terminate);
    assert(terminated.result.exitCode == 143);
}

@("build_primitives.task.executor.run.outcomesIndependentOfCompletionOrder")
@system
unittest
{
    // A diamond with a failing branch: every assignment of durations gives
    // the same outcomes and the same primary cause.
    const g = graphOf([tnode("a"), tnode("b"), tnode("c"), tnode("d"), tnode("s", 1, TaskKind.report)],
        [tedge("a", "b"), tedge("a", "c"), tedge("b", "d"), tedge("c", "d"),
        tedge("d", "s", EdgeCondition.onCompletion), tedge("b", "s", EdgeCondition.onCompletion)]);
    string[] reference;
    foreach (durations; permutations([1, 2, 3]))
    {
        auto run = runFake(g, ["a": Script(durations[0].msecs),
            "b": Script(durations[1].msecs, TaskOutcome(Failed(FailureReason.exitStatus, 1))),
            "c": Script(durations[2].msecs)], ExecutorOptions(capacity: 4));
        string[] outcomes;
        foreach (name; ["a", "b", "c", "d", "s"])
            outcomes ~= run.outcomeOf(g, name);
        if (reference is null)
            reference = outcomes;
        assert(outcomes == reference);
        assert(g[run.result.primaryFailure].id.text == "b");
    }
    assert(reference == ["succeeded", "failed", "succeeded", "blocked", "succeeded"]);
}
