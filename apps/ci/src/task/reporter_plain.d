/++
The plain reporter ([SPEC §10.3, §10.4](../../../../docs/specs/ci/task-dag/SPEC.md)):
the deterministic non-TTY transcript, and `--interlaced` streaming.

$(B Default.) Each task's output is spooled, and its block — every line
prefixed `[<id> <stream>] `, then exactly one terminal line `<id>: <outcome>`
— is written once that task and every task before it in presentation order
are terminal. The transcript is a function of the events' content alone:
the same graph and outcomes give the same bytes whatever order tasks
finished in. Timings are the one exception and are written only when
`PlainOptions.timings` asks for them.

$(B Interlaced.) Each output line is written, prefixed, as soon as it
arrives; across tasks the order is the run's. The terminal lines and the
summary still come at the end, in presentation order.

Every write is one whole line, so a line is never split by another task's.
No cursor movement, spinner, or colour is ever written.
+/
module task.reporter_plain;

import core.time : Duration, MonoTime;
import std.range.primitives : put;
import std.sumtype : match;

import sparkles.base.text.writers : writeDuration;

import task.graph : TaskGraph;
import task.model;
import task.output : SpooledLine;
import task.reporter;

/// Plain reporter settings.
struct PlainOptions
{
    /// Stream lines as they arrive instead of replaying ordered blocks.
    bool interlaced;
    /// Write elapsed times (per task and for the run). Off makes the
    /// transcript byte-identical across completion orders.
    bool timings = true;
    /// Bytes of output each buffered task keeps in memory.
    size_t memoryBudget = 1024 * 1024;
    /// Where buffered output past the budget spills; null drops the oldest.
    string spillRoot;
}

/**
The plain reporter over an output range of `char`. `writer` receives whole
lines, each ending in `\n`.
*/
struct PlainReporter(Writer)
{
    @disable this();
    @disable this(this);

    ///
    this(Writer* writer, const(TaskGraph)* graph, PlainOptions options) @safe
    {
        this.writer = writer;
        this.graph = graph;
        this.options = options;
        blocks = OrderedBlocks(graph.nodes.length, options.memoryBudget,
            options.interlaced ? null : options.spillRoot);
    }

    /// Consumes one event.
    void onEvent(const ref TaskEvent e)
    {
        if (!started)
        {
            started = true;
            firstAt = e.at;
        }
        lastAt = e.at;
        e.payload.match!(
            (const TaskOutput o) {
                if (options.interlaced)
                    writeLine(o.task, o.stream, e.text);
                else
                    blocks.output(o.task, o.stream, e.text, o.unterminated);
            },
            (const TaskFinished f) {
                blocks.finished(f.task, f.outcome, f.elapsed);
                tally.add(f.outcome);
                if (!options.interlaced)
                    blocks.release(&writeBlock);
            },
            (const CancellationRequested c) {
                facts.cancelled = true;
                facts.cancelCause = c.cause;
                facts.causalTask = c.causalTask;
            },
            (const RunFinished r) {
                facts.exitCode = r.exitCode;
                ended = true;
            },
            (_) {},
        );
    }

    /// Writes what remains — the interlaced terminal lines — and the summary.
    void finish()
    {
        if (finished)
            return;
        finished = true;
        if (options.interlaced)
            blocks.releaseAll(&writeTerminal);
        else
            blocks.releaseAll(&writeBlock);
        facts.timings = options.timings;
        facts.wall = lastAt - firstAt;
        if (!ended)
            facts.exitCode = 1; // the stream ended before the run did
        auto outcomes = new TaskOutcome[graph.nodes.length];
        foreach (i; 0 .. outcomes.length)
            outcomes[i] = blocks.outcome(TaskIndex(cast(uint) i));
        writeSummary(*writer, *graph, tally, outcomes, facts);
    }

private:
    Writer* writer;
    const(TaskGraph)* graph;
    PlainOptions options;
    OrderedBlocks blocks;
    RunTally tally;
    SummaryFacts facts;
    bool started, ended, finished;
    MonoTime firstAt, lastAt;

    void writeLine(TaskIndex t, OutputStream stream, scope const(char)[] text)
    {
        writeLinePrefix(*writer, *graph, t, stream);
        put(*writer, text);
        put(*writer, '\n');
    }

    void writeBlock(TaskIndex t)
    {
        blocks.spool(t).replay((const ref SpooledLine l) { writeLine(t, l.stream, l.text); });
        writeTerminal(t);
    }

    void writeTerminal(TaskIndex t)
    {
        put(*writer, (*graph)[t].id.text);
        put(*writer, ": ");
        if (blocks.isDone(t))
            writeOutcome(*writer, *graph, blocks.outcome(t));
        else
            put(*writer, "unfinished");
        if (options.timings && blocks.isDone(t) && blocks.took(t) > Duration.zero)
        {
            put(*writer, " (");
            writeDuration(*writer, blocks.took(t));
            put(*writer, ')');
        }
        put(*writer, '\n');
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests: transcripts of real executor runs under scrambled completion orders
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import core.time : msecs;
    import std.algorithm.searching : canFind, startsWith;
    import std.algorithm.iteration : map;
    import std.array : appender, array, split;

    import task.executor : ExecutorOptions, runGraph;
    import task.testing;

    private string transcript(const ref TaskGraph g, const(TaskEvent)[] events, PlainOptions options) @system
    {
        auto w = appender!string;
        auto reporter = PlainReporter!(typeof(w))(&w, &g, options);
        foreach (ref e; events)
            reporter.onEvent(e);
        reporter.finish();
        return w[];
    }

    // A graph with every outcome kind: a, b succeed with output; c fails;
    // d is blocked by c; e is skipped by its driver; f is degraded.
    private TaskGraph mixedGraph() @safe pure nothrow
        => graphOf([tnode("a"), tnode("b"), tnode("c"), tnode("d"), tnode("e"), tnode("f")],
            [tedge("c", "d")]);

    private Script[string] mixedScripts(const(int)[] durations) @safe pure nothrow
        => [
            "a": Script(durations[0].msecs, lines: ["a1", "a2"]),
            "b": Script(durations[1].msecs, lines: ["b1"]),
            "c": Script(durations[2].msecs, TaskOutcome(Failed(FailureReason.exitStatus, 3)), ["oops"]),
            "e": Script(durations[3].msecs, TaskOutcome(Skipped(SkipReason.platform))),
            "f": Script(durations[4].msecs, TaskOutcome(Degraded(DegradedReason.noCoverage)), ["f1"]),
        ];
}

@("task.reporter_plain.transcriptIsIdenticalAcrossCompletionOrders")
@system
unittest
{
    const g = mixedGraph();
    enum expected =
        "[a stdout] a1\n"
        ~ "[a stdout] a2\n"
        ~ "a: succeeded\n"
        ~ "[b stdout] b1\n"
        ~ "b: succeeded\n"
        ~ "[c stdout] oops\n"
        ~ "c: failed: exit-status 3\n"
        ~ "d: blocked: prerequisite-failed c\n"
        ~ "e: skipped: platform\n"
        ~ "[f stdout] f1\n"
        ~ "f: degraded: no-coverage\n"
        ~ "summary: 6 tasks: 2 succeeded, 1 failed, 1 degraded, 1 skipped, 1 blocked, 0 cancelled\n"
        ~ "failed: c, d\n"
        ~ "exit: 1\n";

    size_t runs;
    foreach (durations; permutations([1, 2, 3, 4, 5]))
    {
        auto run = runFake(g, mixedScripts(durations), ExecutorOptions(capacity: 3));
        const text = transcript(g, run.events, PlainOptions(timings: false));
        assert(text == expected, text);
        ++runs;
    }
    assert(runs == 120);
}

@("task.reporter_plain.spilledBlocksReplayInFull")
@system
unittest
{
    import sparkles.test_utils.tmpfs : TmpFS;

    auto tmp = TmpFS.create();
    const g = graphOf([tnode("a"), tnode("b")], null);
    string[] many;
    foreach (i; 0 .. 50)
        many ~= "line";
    // b finishes first and must wait, spilled, for a.
    auto run = runFake(g, ["a": Script(5.msecs, lines: ["x"]), "b": Script(1.msecs, lines: many)],
        ExecutorOptions(capacity: 2));
    const text = transcript(g, run.events, PlainOptions(timings: false, memoryBudget: 16, spillRoot: tmp.dir));
    const lines = text.split('\n');
    assert(lines[0] == "[a stdout] x" && lines[1] == "a: succeeded");
    assert(lines[2 .. 52] == many.map!(l => "[b stdout] " ~ l).array);
    assert(lines[52] == "b: succeeded");
}

@("task.reporter_plain.interlacedIsImmediateLineAtomicAndPrefixed")
@system
unittest
{
    const g = mixedGraph();
    foreach (durations; permutations([1, 2, 3, 4, 5]))
    {
        auto run = runFake(g, mixedScripts(durations), ExecutorOptions(capacity: 3));
        const text = transcript(g, run.events, PlainOptions(interlaced: true, timings: false));
        const lines = text.split('\n')[0 .. $ - 1];

        // Every output line is whole and prefixed; the order across tasks is
        // the run's, so compare per task.
        string[][string] perTask;
        size_t outputLines;
        foreach (line; lines)
        {
            if (!line.startsWith("["))
                break;
            ++outputLines;
            const close = line.canFind("] ");
            assert(close, "a prefix closes before its text: " ~ line);
            perTask[line.split(" ")[0][1 .. $]] ~= line;
        }
        assert(outputLines == 5);
        assert(perTask["a"] == ["[a stdout] a1", "[a stdout] a2"]);
        // Output appears before any terminal line, which come sorted at the end.
        assert(lines[outputLines .. outputLines + 6] == ["a: succeeded", "b: succeeded",
            "c: failed: exit-status 3", "d: blocked: prerequisite-failed c", "e: skipped: platform",
            "f: degraded: no-coverage"]);
        assert(lines[$ - 1] == "exit: 1");
    }

    // Output reaches the writer as it arrives, not at the end.
    auto run = runFake(g, mixedScripts([1, 2, 3, 4, 5]), ExecutorOptions(capacity: 3));
    auto w = appender!string;
    auto reporter = PlainReporter!(typeof(w))(&w, &g, PlainOptions(interlaced: true, timings: false));
    foreach (ref e; run.events)
    {
        reporter.onEvent(e);
        if (e.payload.match!((const TaskOutput o) => true, _ => false))
            assert(w[].canFind(e.text ~ "\n"), "an interlaced line is written immediately");
    }
}

@("task.reporter_plain.cancellationAndTimings")
@system
unittest
{
    const g = graphOf([tnode("a"), tnode("b")], null);
    auto run = runFake(g, ["a": Script(2.msecs, TaskOutcome(Failed(FailureReason.signal, 9))),
        "b": Script(10.msecs)], ExecutorOptions(capacity: 2, failFast: true));
    const text = transcript(g, run.events, PlainOptions());
    assert(text.canFind("a: failed: signal 9 (2.0ms)\n"), text);
    assert(text.canFind("b: cancelled: interrupted (10ms)\n"));
    assert(text.canFind("cancelled: fail-fast after a\n"));
    assert(text.canFind("time: 10ms\n"));
    assert(!text.canFind("\x1b"), "plain output carries no control sequence");
}

@("task.reporter_plain.consumeEventsThroughAChannel")
@system
unittest
{
    import sparkles.event_horizon.channel : Channel;
    import sparkles.event_horizon.scope_ : withScope;
    import sparkles.event_horizon.testing : advanceAndSettle, TestSched;

    const g = mixedGraph();
    TestSched sched;
    auto clock = Clock(sched.waker());
    auto driver = FakeDriver(&clock, mixedScripts([5, 4, 3, 2, 1]));
    Channel!(TaskEvent, 2) channel;
    auto w = appender!string;
    auto reporter = PlainReporter!(typeof(w))(&w, &g, PlainOptions(timings: false));
    sched.run(() {
        cast(void) withScope!((ref sc) {
            sc.spawn(() { consumeEvents(sched, channel, reporter); });
            cast(void) runGraph(sched, clock, g, driver, channel, ExecutorOptions(capacity: 2));
            channel.close();
        })(sched);
    });
    advanceAndSettle(sched, clock);
    assert(w[].canFind("summary: 6 tasks:"));
    assert(w[].canFind("exit: 1\n"));
}
