/++
The interactive reporter ([SPEC TDO2, TDO4](../../../../docs/specs/build-primitives/task-dag/SPEC.md)):
`sparkles.ui`'s `TaskReporter` over a `LiveRegion`, driven by task events.

Every planned task registers before any runs, so totals never move. A running
task shows a spinner and a bounded tail of its output. Terminal transitions
graduate into the scrollback in real completion order — this is a live view.
After the region finishes, failed tasks' diagnostic tails are replayed in
presentation order, then the summary: those two parts are deterministic.

With `interlaced`, per-task tails are off and every output line is printed,
prefixed, above the compact frame as it arrives.

On a non-interactive region the frame is never painted and only the
graduated lines, the replay, and the summary are written — no control
sequence. `finish` (called by `consumeEvents` under `protect`) always ends
the region, so the cursor is restored after an interruption too.
+/
module task.reporter_tty;

import core.time : MonoTime;
import std.array : appender;
import std.sumtype : match;

import sparkles.ui.components.live : LiveRegion;
import sparkles.ui.components.tasklist : TaskReporter;
import sparkles.ui.components.theme : Theme;

import sparkles.build_primitives.task.graph : TaskGraph;
import sparkles.build_primitives.task.model;
import sparkles.build_primitives.task.output : SpooledLine;
import sparkles.build_primitives.task.reporter;

/// TTY reporter settings.
struct TtyOptions
{
    /// Print every output line above the frame instead of per-task tails.
    bool interlaced;
    /// Live tail lines per running task.
    size_t tailLines = 4;
    /// Lines of a failed task's output kept for the replay.
    size_t failureTailLines = 20;
    /// Write the run's wall time in the summary.
    bool timings = true;
}

/// The interactive reporter.
struct TtyReporter
{
    @disable this();
    @disable this(this);

    /// Reports into `region` (owned by the caller) with `theme`.
    this(LiveRegion* region, Theme theme, const(TaskGraph)* graph, TtyOptions options)
    {
        this.region = region;
        this.graph = graph;
        this.options = options;
        tasks = TaskReporter(region, theme);
        tasks.tailLines = options.interlaced ? 0 : options.tailLines;
        // A small in-memory spool per task: enough for the failure replay.
        blocks = OrderedBlocks(graph.nodes.length, 64 * 1024, null);
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
            (const GraphPlanned _) {
                foreach (ref n; graph.nodes)
                    cast(void) tasks.add(n.id.text);
            },
            (const TaskStarted s) { tasks.start(s.task.value); },
            (const TaskOutput o) {
                blocks.output(o.task, o.stream, e.text, o.unterminated);
                if (options.interlaced)
                {
                    auto w = appender!string;
                    writeLinePrefix(w, *graph, o.task, o.stream);
                    w.put(e.text);
                    region.printAbove(w[]);
                }
                else
                    tasks.output(o.task.value, e.text);
            },
            (const TaskFinished f) {
                blocks.finished(f.task, f.outcome, f.elapsed);
                tally.add(f.outcome);
                graduate(f.task, f.outcome);
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

    /// Ends the live region, replays failures, and writes the summary.
    void finish()
    {
        if (finished)
            return;
        finished = true;
        region.finish();
        auto outcomes = new TaskOutcome[graph.nodes.length];
        foreach (i, ref n; graph.nodes)
        {
            const t = TaskIndex(cast(uint) i);
            outcomes[i] = blocks.outcome(t);
            if (!blocks.isDone(t) || kindOf(outcomes[i]) != OutcomeKind.failed)
                continue;
            auto header = appender!string;
            header.put("── ");
            header.put(n.id.text);
            header.put(": ");
            writeOutcome(header, *graph, outcomes[i]);
            region.printAbove(header[]);
            const tail = blocks.spool(t).tail;
            const from = tail.length > options.failureTailLines ? tail.length - options.failureTailLines : 0;
            foreach (ref line; tail[from .. $])
            {
                auto w = appender!string;
                writeLinePrefix(w, *graph, t, line.stream);
                w.put(line.text);
                region.printAbove(w[]);
            }
        }
        facts.timings = options.timings;
        facts.wall = lastAt - firstAt;
        if (!ended)
            facts.exitCode = 1;
        auto summary = appender!string;
        writeSummary(summary, *graph, tally, outcomes, facts);
        import std.string : lineSplitter;

        foreach (line; summary[].lineSplitter)
            region.printAbove(line);
    }

private:
    LiveRegion* region;
    const(TaskGraph)* graph;
    TtyOptions options;
    TaskReporter tasks;
    OrderedBlocks blocks;
    RunTally tally;
    SummaryFacts facts;
    bool started, ended, finished;
    MonoTime firstAt, lastAt;

    void graduate(TaskIndex t, const TaskOutcome outcome)
    {
        auto detail = appender!string;
        writeOutcome(detail, *graph, outcome);
        final switch (kindOf(outcome))
        {
            case OutcomeKind.succeeded:
                tasks.succeed(t.value);
                break;
            case OutcomeKind.degraded:
                tasks.succeed(t.value, detail[]);
                break;
            case OutcomeKind.failed:
                tasks.fail(t.value, detail[]);
                break;
            case OutcomeKind.blocked:
                if (failsCommand(outcome))
                    tasks.fail(t.value, detail[]);
                else
                    tasks.skip(t.value, detail[]);
                break;
            case OutcomeKind.skipped:
            case OutcomeKind.cancelled:
                tasks.skip(t.value, detail[]);
                break;
        }
    }
}

version (unittest)
{
    import core.time : msecs;
    import std.algorithm.searching : canFind, count;

    import sparkles.build_primitives.task.executor : ExecutorOptions;
    import sparkles.build_primitives.task.testing;

    private enum Theme plain = Theme(colors: false, unicode: true);

    private string render(const ref TaskGraph g, const(TaskEvent)[] events, bool interactive,
        TtyOptions options = TtyOptions(timings: false), size_t stopAfter = size_t.max) @system
    {
        string bytes;
        auto region = LiveRegion((scope const(char)[] b) { bytes ~= b; }, () => ushort(80), interactive);
        auto reporter = TtyReporter(&region, plain, &g, options);
        foreach (i, ref e; events)
        {
            if (i == stopAfter)
                break;
            reporter.onEvent(e);
        }
        reporter.finish();
        return bytes;
    }

    private TaskGraph ttyGraph() @safe pure nothrow
        => graphOf([tnode("a"), tnode("b"), tnode("c")], [tedge("b", "c")]);

    private Script[string] ttyScripts() @safe pure nothrow
        => ["a": Script(2.msecs, lines: ["hello"]),
            "b": Script(1.msecs, TaskOutcome(Failed(FailureReason.exitStatus, 2)), ["bad 1", "bad 2"])];
}

@("task.reporter_tty.nonInteractiveDegradesToPlainLines")
@system
unittest
{
    const g = ttyGraph();
    auto run = runFake(g, ttyScripts(), ExecutorOptions(capacity: 2));
    const bytes = render(g, run.events, false);
    assert(!bytes.canFind('\x1b'), "no control sequence without a terminal");
    assert(bytes.canFind("✔ a"));
    assert(bytes.canFind("✖ b failed: exit-status 2"));
    assert(bytes.canFind("✖ c blocked: prerequisite-failed b"));
    // The failure replay and summary come after, in presentation order.
    assert(bytes.canFind("── b: failed: exit-status 2\n[b stdout] bad 1\n[b stdout] bad 2\n"));
    assert(bytes.canFind("summary: 3 tasks: 1 succeeded, 1 failed, 0 degraded, 0 skipped, 1 blocked, 0 cancelled\n"));
    assert(bytes.canFind("exit: 1\n"));
}

@("task.reporter_tty.interactiveShowsTailsAndRestoresTheCursor")
@system
unittest
{
    import sparkles.base.term_control : CtlSeq;

    const g = ttyGraph();
    auto run = runFake(g, ttyScripts(), ExecutorOptions(capacity: 2));
    const bytes = render(g, run.events, true);
    assert(bytes.canFind(cast(string) CtlSeq.hideCursor));
    assert(bytes.canFind("  hello"), "a running task's tail is painted");
    assert(bytes.canFind(cast(string) CtlSeq.showCursor), "finish restores the cursor");

    // Interrupted midway (the event stream stops): finish still restores
    // the cursor and the summary marks the run unfinished.
    const cut = render(g, run.events, true, TtyOptions(timings: false), 4);
    assert(cut.canFind(cast(string) CtlSeq.showCursor));
    assert(cut.canFind("exit: 1"));
}

@("task.reporter_tty.interlacedPrintsPrefixedLinesAboveTheFrame")
@system
unittest
{
    const g = ttyGraph();
    auto run = runFake(g, ttyScripts(), ExecutorOptions(capacity: 2));
    const bytes = render(g, run.events, false, TtyOptions(interlaced: true, timings: false));
    assert(bytes.canFind("[a stdout] hello\n"));
    assert(bytes.count("[b stdout] bad 1\n") == 2, "once live, once in the failure replay");
}
