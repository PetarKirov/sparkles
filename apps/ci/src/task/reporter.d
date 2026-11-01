/++
What every reporter shares ([SPEC §10](../../../../docs/specs/ci/task-dag/SPEC.md)):
the reporter and event-source concepts, the consumer loop, the ordered block
buffer, outcome wording, and the run summary.

A reporter is the single writer of the command's UI streams. It consumes the
executor's events and never influences scheduling. Its deterministic parts —
blocks replayed in presentation order, terminal lines, the summary — depend
only on the events' content, never on their arrival order.

Reporters know events and the graph, not commands. No concrete reporter is
imported here.
+/
module task.reporter;

import core.time : Duration, MonoTime;
import std.range.primitives : put;
import std.sumtype : match;

import sparkles.base.text.wire_names : AnyFormat;
import sparkles.base.text.writers : writeDuration, writeEnumMemberName, writeValue;
import sparkles.event_horizon.capability : isFiberExecutor;
import sparkles.event_horizon.scope_ : protect;

import task.graph : TaskGraph;
import task.model;
import task.output : OutputSpool, SpooledLine;

/// Whether `R` consumes task events: `onEvent(const ref TaskEvent)` per
/// event, then `finish()` once.
enum bool isReporter(R) = __traits(compiles, (ref R r, const ref TaskEvent e) {
    r.onEvent(e);
    r.finish();
});

/// Whether `Src` yields events on executor `X`: the shape of `Channel.take`
/// and of the cross-worker channel.
enum bool isEventSource(Src, X) = __traits(compiles, (ref Src s, ref X x) {
    auto r = s.take(x);
    bool ended = r.hasError;
    TaskEvent e = r.value;
});

/**
The reporter fiber's body: hands every event from `source` to `reporter`
until the source is closed and drained (or the fiber is cancelled), then
calls `reporter.finish()` under `protect`, so terminal restoration runs on
success, failure, and cancellation alike.
*/
void consumeEvents(X, Src, R)(ref X exec, ref Src source, ref R reporter)
if (isFiberExecutor!X && isEventSource!(Src, X) && isReporter!R)
{
    scope (exit)
        protect!(() { reporter.finish(); })(exec);
    for (;;)
    {
        auto e = source.take(exec);
        if (e.hasError)
            break;
        reporter.onEvent(e.value);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ordered blocks
// ─────────────────────────────────────────────────────────────────────────────

/**
Buffers each task's output and releases complete blocks in presentation
order: task `i`'s block is released once it and every task before it are
terminal ([SPEC §10.3]). Output beyond the memory budget spills under
`spillRoot`, as the process adapter's does.
*/
struct OrderedBlocks
{
    @disable this();
    @disable this(this);

    /// Blocks for `taskCount` tasks.
    this(size_t taskCount, size_t memoryBudget, string spillRoot) @safe
    {
        import std.conv : text;
        import std.path : buildPath;

        spools = new OutputSpool[taskCount];
        foreach (i, ref s; spools)
            s = OutputSpool(memoryBudget, spillRoot.length ? spillRoot.buildPath(text(i) ~ ".log") : null);
        outcomes = new TaskOutcome[taskCount];
        elapsed = new Duration[taskCount];
        done = new bool[taskCount];
    }

    /// Records an output line.
    void output(TaskIndex t, OutputStream stream, scope const(char)[] text, bool unterminated) @safe
        => spools[t.value].append(stream, text, unterminated);

    /// Records a terminal outcome.
    void finished(TaskIndex t, TaskOutcome outcome, Duration took) @safe pure nothrow @nogc
    {
        outcomes[t.value] = outcome;
        elapsed[t.value] = took;
        done[t.value] = true;
    }

    /// Calls `emit` for every block now releasable, in order.
    void release(Emit)(scope Emit emit)
    {
        while (next < done.length && done[next])
            emit(TaskIndex(cast(uint) next++));
    }

    /// Releases everything left, terminal or not (the run ended early).
    void releaseAll(Emit)(scope Emit emit)
    {
        while (next < done.length)
            emit(TaskIndex(cast(uint) next++));
    }

    /// Task `t`'s spool.
    ref OutputSpool spool(TaskIndex t) return @safe pure nothrow @nogc => spools[t.value];

    /// Task `t`'s outcome, once terminal.
    TaskOutcome outcome(TaskIndex t) const @safe pure nothrow @nogc => outcomes[t.value];

    /// Whether `t` is terminal.
    bool isDone(TaskIndex t) const @safe pure nothrow @nogc => done[t.value];

    /// Task `t`'s elapsed time.
    Duration took(TaskIndex t) const @safe pure nothrow @nogc => elapsed[t.value];

private:
    OutputSpool[] spools;
    TaskOutcome[] outcomes;
    Duration[] elapsed;
    bool[] done;
    size_t next;
}

@("task.reporter.OrderedBlocks.releasesInPresentationOrder")
@safe
unittest
{
    auto blocks = OrderedBlocks(3, 1024, null);
    uint[] released;
    void emit(TaskIndex t) { released ~= t.value; }

    blocks.finished(TaskIndex(2), TaskOutcome(Succeeded()), Duration.zero);
    blocks.release(&emit);
    assert(released.length == 0, "task 2 waits for 0 and 1");
    blocks.finished(TaskIndex(0), TaskOutcome(Succeeded()), Duration.zero);
    blocks.release(&emit);
    assert(released == [0]);
    blocks.finished(TaskIndex(1), TaskOutcome(Succeeded()), Duration.zero);
    blocks.release(&emit);
    assert(released == [0, 1, 2]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Wording
// ─────────────────────────────────────────────────────────────────────────────

/**
Writes `outcome` as its kind and reason: `succeeded`, `failed: exit-status 3`,
`failed: signal 9`, `skipped: platform`, `cancelled: not-admitted`,
`blocked: prerequisite-failed test:a`, `degraded: no-coverage`.
*/
void writeOutcome(Writer)(ref Writer w, const ref TaskGraph graph, const TaskOutcome outcome)
{
    writeEnumMemberName!AnyFormat(w, kindOf(outcome));
    outcome.match!(
        (const Succeeded _) {},
        (const Failed f) {
            put(w, ": ");
            writeEnumMemberName!AnyFormat(w, f.reason);
            if (f.reason == FailureReason.exitStatus || f.reason == FailureReason.signal
                || (f.reason == FailureReason.spawnFailed && f.status))
            {
                put(w, ' ');
                writeValue(w, f.status);
            }
        },
        (const Skipped s) { put(w, ": "); writeEnumMemberName!AnyFormat(w, s.reason); },
        (const Cancelled c) { put(w, ": "); writeEnumMemberName!AnyFormat(w, c.reason); },
        (const Blocked b) {
            put(w, ": ");
            writeEnumMemberName!AnyFormat(w, b.reason);
            if (b.cause.valid)
            {
                put(w, ' ');
                put(w, graph[b.cause].id.text);
            }
        },
        (const Degraded d) { put(w, ": "); writeEnumMemberName!AnyFormat(w, d.reason); },
    );
}

/// Outcome counts for the summary.
struct RunTally
{
    size_t[OutcomeKind.max + 1] counts; ///

    /// Counts `outcome`.
    void add(const TaskOutcome outcome) @safe pure nothrow @nogc { counts[kindOf(outcome)]++; }

    /// Tasks counted.
    size_t total() const @safe pure nothrow @nogc
    {
        size_t n;
        foreach (c; counts)
            n += c;
        return n;
    }
}

/// What the summary reports besides the counts.
struct SummaryFacts
{
    bool cancelled;          ///
    CancelCause cancelCause; ///
    TaskIndex causalTask;    /// the fail-fast trigger, when valid
    int exitCode;            ///
    bool timings;            /// write the wall time
    Duration wall;           ///
}

/**
Writes the final summary ([SPEC §10.2]): every outcome count — succeeded,
failed, degraded, skipped, blocked, cancelled — then the cancellation, the
failed and blocked-by-failure tasks in presentation order, the wall time when
wanted, and the exit status.

---
summary: 4 tasks: 2 succeeded, 1 failed, 0 degraded, 0 skipped, 1 blocked, 0 cancelled
cancelled: fail-fast after test:a
failed: test:a, test:b
exit: 1
---
*/
void writeSummary(Writer)(ref Writer w, const ref TaskGraph graph, const ref RunTally tally,
    scope const(TaskOutcome)[] outcomes, const SummaryFacts facts)
{
    put(w, "summary: ");
    writeValue(w, tally.total);
    put(w, " tasks: ");
    static immutable OutcomeKind[6] order = [OutcomeKind.succeeded, OutcomeKind.failed,
        OutcomeKind.degraded, OutcomeKind.skipped, OutcomeKind.blocked, OutcomeKind.cancelled];
    foreach (i, kind; order)
    {
        if (i)
            put(w, ", ");
        writeValue(w, tally.counts[kind]);
        put(w, ' ');
        writeEnumMemberName!AnyFormat(w, kind);
    }
    put(w, '\n');
    if (facts.cancelled)
    {
        put(w, "cancelled: ");
        writeEnumMemberName!AnyFormat(w, facts.cancelCause);
        if (facts.causalTask.valid)
        {
            put(w, " after ");
            put(w, graph[facts.causalTask].id.text);
        }
        put(w, '\n');
    }
    bool any;
    foreach (i, ref outcome; outcomes)
        if (failsCommand(outcome) && graph.nodes[i].failurePolicy == FailurePolicy.authoritative)
        {
            put(w, any ? ", " : "failed: ");
            put(w, graph.nodes[i].id.text);
            any = true;
        }
    if (any)
        put(w, '\n');
    if (facts.timings)
    {
        put(w, "time: ");
        writeDuration(w, facts.wall);
        put(w, '\n');
    }
    put(w, "exit: ");
    writeValue(w, facts.exitCode);
    put(w, '\n');
}

/// Writes a line's prefix: `[<id> stdout] `.
void writeLinePrefix(Writer)(ref Writer w, const ref TaskGraph graph, TaskIndex t, OutputStream stream)
{
    put(w, '[');
    put(w, graph[t].id.text);
    put(w, ' ');
    writeEnumMemberName!AnyFormat(w, stream);
    put(w, "] ");
}
