/++
The plain reporter ([SPEC TDO3, TDO4](../../../../../../docs/specs/build-primitives/task-dag/SPEC.md)):
the deterministic non-TTY transcript, and `--interlaced` streaming.

$(B Default.) Each task's output is spooled, and its block — every line
prefixed `[<id> <stream>] `, then exactly one terminal line `<id>: <outcome>`
— is written once that task and every task before it in presentation order
are terminal. The transcript is a function of the events' content alone:
the same graph and outcomes give the same bytes whatever order tasks
finished in. Timings are the one exception and are written only when
`PlainOptions.timings` asks for them.

$(B Interlaced.) Each output line is written, prefixed, as soon as it
arrives; across tasks the order is the run's. The terminal lines, a replay
of each failed task's output tail, and the summary still come at the end, in
presentation order.

$(B CI providers) ([task-DAG SPEC TDO6, TDO7](../../../../../../docs/specs/build-primitives/task-dag/SPEC.md)).
With `PlainOptions.ci` set to a provider that has groups, each replayed
block with output is wrapped in a group titled `<id>: <outcome>`, its
terminal line following the group. Interlaced lines are never grouped,
since several tasks' lines interleave; instead the final terminal-line
section and the failure replay become one group each. Before any output,
every redacted environment value in the graph is masked on the provider.

Every write is one whole line, so a line is never split by another task's.
No cursor movement, spinner, or colour is ever written.
+/
module sparkles.build_primitives.task.reporter_plain;

import core.time : Duration, MonoTime;
import std.range.primitives : put;
import std.sumtype : match;

import sparkles.base.text.writers : writeDuration;

import sparkles.ci_provider : CiLog;
import sparkles.build_primitives.task.action : ProcessAction;

import sparkles.build_primitives.task.graph : TaskGraph;
import sparkles.build_primitives.task.model;
import sparkles.build_primitives.task.output : SpooledLine;
import sparkles.build_primitives.task.reporter;

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
    /// The CI provider's conventions (`CiLog.detect(&systemEnvironment)`);
    /// the default has none, and writes no group or mask.
    CiLog ci;
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
            writeMasks();
            // Interlaced lines stream until `finish`: fence them all at once.
            if (options.interlaced)
                options.ci.beginUntrusted(*writer);
        }
        lastAt = e.at;
        e.payload.match!(
            (const TaskOutput o) {
                // A node whose policy is not `replay` is written once it is
                // terminal, even interlaced: which lines show depends on how
                // it ended (TDO3, TDO4).
                if (options.interlaced && policy(o.task) == OutputPolicy.replay)
                    writeLine(o.task, o.stream, e.text);
                blocks.output(o.task, o.stream, e.text, o.unterminated);
            },
            (const TaskNotice n) {
                // A notice shows whatever the policy (TDM21): interlaced, it
                // streams at once; buffered, its block holds it.
                if (options.interlaced)
                    writeNotice(n.task, e.text);
                blocks.notice(n.task, e.text);
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
            (const TaskFresh f) { blocks.freshness(f.task, FreshnessNote.of(e)); },
            (const TaskStale s) { blocks.freshness(s.task, FreshnessNote.of(e)); },
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
        {
            if (started)
                options.ci.endUntrusted(*writer);
            // One line per task: collapsed, the failures below stay in view.
            if (options.ci.groups)
                options.ci.openGroup(*writer, "results", collapsed: true);
            blocks.releaseAll(&writeHeldAndTerminal);
            if (options.ci.groups)
                options.ci.closeGroup(*writer);
            writeFailureReplay();
        }
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

    OutputPolicy policy(TaskIndex t) => (*graph)[t].outputPolicy;

    // A line, prefixed; text holding line breaks (a multi-line message sent
    // as one) is written as that many lines, each prefixed.
    void writeLine(TaskIndex t, OutputStream stream, scope const(char)[] text)
        => writePrefixed(t, notice: false, stream, text);

    // A notice (TDM21), as a line prefixed `[<label> notice] `.
    void writeNotice(TaskIndex t, scope const(char)[] text) => writePrefixed(t, notice: true, OutputStream.init, text);

    void writePrefixed(TaskIndex t, bool notice, OutputStream stream, scope const(char)[] text)
    {
        while (true)
        {
            size_t end;
            while (end < text.length && text[end] != '\n')
                ++end;
            if (notice)
                writeNoticePrefix(*writer, *graph, t);
            else
                writeLinePrefix(*writer, *graph, t, stream);
            options.ci.writeUntrusted(*writer, text[0 .. end]);
            put(*writer, '\n');
            if (end >= text.length)
                break;
            text = text[end + 1 .. $];
        }
    }

    // Which of a terminal task's lines its policy shows (TDO3): all, its
    // tail when it did not succeed, its last line when it did
    // (`lastLineOnSuccess`), or none.
    enum Shown { none, all, tail, last }
    Shown shown(TaskIndex t)
    {
        if (blocks.spool(t).lines == 0)
            return Shown.none;
        const succeeded = blocks.isDone(t) && kindOf(blocks.outcome(t)) == OutcomeKind.succeeded;
        final switch (policy(t))
        {
            case OutputPolicy.replay: return Shown.all;
            case OutputPolicy.none: return Shown.none;
            case OutputPolicy.tailOnFailure: return succeeded ? Shown.none : Shown.tail;
            case OutputPolicy.lastLineOnSuccess: return succeeded ? Shown.last : Shown.tail;
        }
    }

    void writeShown(TaskIndex t, Shown what)
    {
        options.ci.beginUntrusted(*writer);
        final switch (what)
        {
            case Shown.none: break;
            case Shown.all:
                blocks.spool(t).replay((const ref SpooledLine l) { writeLine(t, l.stream, l.text); });
                break;
            case Shown.tail:
                foreach (ref l; blocks.spool(t).tail)
                    writeLine(t, l.stream, l.text);
                break;
            case Shown.last:
                const tail = blocks.spool(t).tail;
                if (tail.length)
                    writeLine(t, tail[$ - 1].stream, tail[$ - 1].text);
                break;
        }
        options.ci.endUntrusted(*writer);
    }

    // A block's lines, as its policy shows them, then its driver's notices,
    // whatever the policy (TDM21), each fenced from the provider's command
    // parser. The notices stay outside the block's group, which a provider
    // folds away.
    void writeBlock(TaskIndex t)
    {
        const what = shown(t);
        const grouped = options.ci.groups && what != Shown.none;
        if (grouped)
            options.ci.openGroup(*writer, blockTitle(t));
        if (what != Shown.none)
            writeShown(t, what);
        if (grouped)
            options.ci.closeGroup(*writer);
        const notices = blocks.noticesOf(t);
        if (notices.length)
        {
            options.ci.beginUntrusted(*writer);
            foreach (n; notices)
                writeNotice(t, n);
            options.ci.endUntrusted(*writer);
        }
        writeTerminal(t);
    }

    // Interlaced: the lines a non-`replay` node held until it ended, but a
    // failure's, which the failure replay shows; then its terminal line.
    void writeHeldAndTerminal(TaskIndex t)
    {
        if (policy(t) != OutputPolicy.replay)
        {
            const what = shown(t);
            if (what == Shown.last)
                writeShown(t, what);
        }
        writeTerminal(t);
    }

    // `<id>: <outcome>`: a group's title.
    string blockTitle(TaskIndex t)
    {
        import std.array : appender;

        auto title = appender!string;
        title.put(displayName(*graph, t));
        title.put(": ");
        if (blocks.isDone(t))
            writeOutcome(title, *graph, blocks.outcome(t));
        else
            title.put("unfinished");
        writeFreshness(title, blocks.freshness(t));
        return title[];
    }

    // Interlaced: each failed task's output tail again, in presentation
    // order, so a failure's lines read together.
    void writeFailureReplay()
    {
        bool any;
        foreach (i; 0 .. graph.nodes.length)
        {
            const t = TaskIndex(cast(uint) i);
            if (!blocks.isDone(t) || kindOf(blocks.outcome(t)) != OutcomeKind.failed || policy(t) == OutputPolicy.none
                || blocks.spool(t).lines == 0)
                continue;
            if (!any)
            {
                any = true;
                if (options.ci.groups)
                    options.ci.openGroup(*writer, "failures", collapsed: false);
            }
            put(*writer, "failure ");
            put(*writer, blockTitle(t));
            put(*writer, '\n');
            options.ci.beginUntrusted(*writer);
            foreach (ref line; blocks.spool(t).tail)
                writeLine(t, line.stream, line.text);
            options.ci.endUntrusted(*writer);
        }
        if (any && options.ci.groups)
            options.ci.closeGroup(*writer);
    }

    // Masks every redacted environment value the graph's actions carry.
    void writeMasks()
    {
        foreach (ref node; graph.nodes)
            node.action.match!(
                (const ref ProcessAction p) {
                    foreach (entry; p.envDelta)
                        if (entry.redacted)
                            options.ci.mask(*writer, entry.name, entry.value);
                },
                (_) {},
            );
    }

    void writeTerminal(TaskIndex t)
    {
        put(*writer, displayName(*graph, t));
        put(*writer, ": ");
        if (blocks.isDone(t))
            writeOutcome(*writer, *graph, blocks.outcome(t));
        else
            put(*writer, "unfinished");
        writeFreshness(*writer, blocks.freshness(t));
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

    import sparkles.build_primitives.task.executor : ExecutorOptions, runGraph;
    import sparkles.build_primitives.task.testing;

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

@("build_primitives.task.reporter_plain.transcriptIsIdenticalAcrossCompletionOrders")
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
        ~ "summary: 6 tasks: 2 succeeded, 1 failed, 1 degraded, 1 skipped, 1 blocked, 0 unneeded, 0 cancelled\n"
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

@("build_primitives.task.reporter_plain.spilledBlocksReplayInFull")
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

@("build_primitives.task.reporter_plain.interlacedIsImmediateLineAtomicAndPrefixed")
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

@("build_primitives.task.reporter_plain.cancellationAndTimings")
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

/// BGW19: a task's line says why it ran, in terms of a path, or that it was
/// fresh.
@("build_primitives.task.reporter_plain.freshAndStale")
@system
unittest
{
    const Digest inputs = 1;
    const g = graphOf([tnode("a"), tnode("b"), tnode("c")], [tedge("b", "c")]);
    auto run = runFake(g, [
        "a": Script(1.msecs, freshness: Freshness(Freshness.Kind.fresh, inputs)),
        "b": Script(2.msecs, freshness: Freshness(Freshness.Kind.stale,
            reason: StaleReason.inputChanged, path: "libs/base/src/buffer.d")),
        "c": Script(1.msecs, freshness: Freshness(Freshness.Kind.fresh, inputs)),
    ], ExecutorOptions(capacity: 2));
    const text = transcript(g, run.events, PlainOptions(timings: false));
    assert(text.startsWith("a: succeeded, fresh\n"
        ~ "b: succeeded, ran: libs/base/src/buffer.d changed\n"
        ~ "c: succeeded, ran: a prerequisite ran\n"), text);
}

@("build_primitives.task.reporter_plain.consumeEventsThroughAChannel")
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

@("build_primitives.task.reporter_plain.ci.groupsReplayedBlocks")
@system
unittest
{
    import sparkles.ci_provider : CiProvider;

    const g = mixedGraph();
    auto run = runFake(g, mixedScripts([1, 2, 3, 4, 5]), ExecutorOptions(capacity: 3));
    CiLog github;
    github.provider = CiProvider.githubActions;
    github.stopToken = "feedfacefeedfacefeedfacefeedface";
    const text = transcript(g, run.events, PlainOptions(timings: false, ci: github));
    enum stop = "::stop-commands::feedfacefeedfacefeedfacefeedface\n";
    enum resume = "::feedfacefeedfacefeedfacefeedface::\n";
    assert(text ==
        "::group::a: succeeded\n"
        ~ stop
        ~ "[a stdout] a1\n"
        ~ "[a stdout] a2\n"
        ~ resume
        ~ "::endgroup::\n"
        ~ "a: succeeded\n"
        ~ "::group::b: succeeded\n"
        ~ stop
        ~ "[b stdout] b1\n"
        ~ resume
        ~ "::endgroup::\n"
        ~ "b: succeeded\n"
        ~ "::group::c: failed: exit-status 3\n"
        ~ stop
        ~ "[c stdout] oops\n"
        ~ resume
        ~ "::endgroup::\n"
        ~ "c: failed: exit-status 3\n"
        ~ "d: blocked: prerequisite-failed c\n"
        ~ "e: skipped: platform\n"
        ~ "::group::f: degraded: no-coverage\n"
        ~ stop
        ~ "[f stdout] f1\n"
        ~ resume
        ~ "::endgroup::\n"
        ~ "f: degraded: no-coverage\n"
        ~ "summary: 6 tasks: 2 succeeded, 1 failed, 1 degraded, 1 skipped, 1 blocked, 0 unneeded, 0 cancelled\n"
        ~ "failed: c, d\n"
        ~ "exit: 1\n", text);

    // Without a provider, the transcript is the plain one: no group syntax.
    const plain = transcript(g, run.events, PlainOptions(timings: false));
    assert(!plain.canFind("::"));
}

@("build_primitives.task.reporter_plain.ci.childOutputIsNeverACommand")
@system
unittest
{
    import sparkles.ci_provider : CiProvider;

    // A child prints workflow commands of both providers; the reporter
    // must not let the provider read any of them (TDO7).
    const g = graphOf([tnode("a")], null);
    auto run = runFake(g, ["a": Script(1.msecs, TaskOutcome(Failed(FailureReason.exitStatus, 1)),
        ["::add-mask::x", "::error::boom", "##vso[task.complete result=Failed]"])],
        ExecutorOptions(capacity: 1));
    enum token = "0123456789abcdef0123456789abcdef";
    enum fenced = "::stop-commands::" ~ token ~ "\n"
        ~ "[a stdout] ::add-mask::x\n"
        ~ "[a stdout] ::error::boom\n"
        ~ "[a stdout] ##vso[task.complete result=Failed]\n"
        ~ "::" ~ token ~ "::\n";

    CiLog github;
    github.provider = CiProvider.githubActions;
    github.stopToken = token;
    foreach (interlaced; [false, true])
    {
        const text = transcript(g, run.events, PlainOptions(interlaced: interlaced, timings: false, ci: github));
        assert(text.canFind(fenced), text);
        // Outside the fences, only the reporter's own commands remain.
        foreach (line; text.split('\n'))
            if (line.startsWith("::"))
                assert(line.startsWith("::group::") || line.startsWith("::endgroup::")
                    || line.startsWith("::stop-commands::") || line == "::" ~ token ~ "::", line);
    }

    CiLog azure;
    azure.provider = CiProvider.azurePipelines;
    foreach (interlaced; [false, true])
    {
        const text = transcript(g, run.events, PlainOptions(interlaced: interlaced, timings: false, ci: azure));
        assert(!text.canFind("##vso["), "an Azure command is broken in the child's line");
        assert(text.canFind("[a stdout] #​#vso[task.complete result=Failed]\n"));
    }
}

@("build_primitives.task.reporter_plain.ci.interlacedGroupsOnlyTheFinalSections")
@system
unittest
{
    import sparkles.ci_provider : CiProvider;

    static long pinned() @safe nothrow @nogc => 42;

    const g = mixedGraph();
    auto run = runFake(g, mixedScripts([5, 4, 3, 2, 1]), ExecutorOptions(capacity: 3));
    CiLog gitlab;
    gitlab.provider = CiProvider.gitlabCi;
    gitlab.unixTime = &pinned;
    const text = transcript(g, run.events, PlainOptions(interlaced: true, timings: false, ci: gitlab));
    const lines = text.split('\n')[0 .. $ - 1];

    // The interleaved output comes first, ungrouped.
    size_t i;
    while (lines[i].startsWith("["))
        ++i;
    assert(i == 5);
    assert(lines[i .. $] == [
        "\x1b[0Ksection_start:42:task_1[collapsed=true]\r\x1b[0Kresults",
        "a: succeeded", "b: succeeded", "c: failed: exit-status 3",
        "d: blocked: prerequisite-failed c", "e: skipped: platform", "f: degraded: no-coverage",
        "\x1b[0Ksection_end:42:task_1\r\x1b[0K",
        "\x1b[0Ksection_start:42:task_2\r\x1b[0Kfailures",
        "failure c: failed: exit-status 3",
        "[c stdout] oops",
        "\x1b[0Ksection_end:42:task_2\r\x1b[0K",
        "summary: 6 tasks: 2 succeeded, 1 failed, 1 degraded, 1 skipped, 1 blocked, 0 unneeded, 0 cancelled",
        "failed: c, d",
        "exit: 1",
    ], text);
}

@("build_primitives.task.reporter_plain.ci.masksRedactedValuesFirst")
@system
unittest
{
    import sparkles.ci_provider : CiProvider;
    import sparkles.build_primitives.task.action : EnvEntry, ProcessAction;
    import sparkles.build_primitives.task.graph : TaskGraphBuilder;

    TaskGraphBuilder b;
    b.add(TaskNode(taskId("a").value, TaskKind.fetch, "a", PresentationKey(0, "a"), ResourceClaim(1),
        TaskAction(ProcessAction(["gh", "api"], [EnvEntry("GH_TOKEN", "hunter2", redacted: true),
            EnvEntry("PLAIN", "visible")]))));
    const g = b.build().value;
    auto run = runFake(g, null, ExecutorOptions(capacity: 1));

    CiLog github;
    github.provider = CiProvider.githubActions;
    const masked = transcript(g, run.events, PlainOptions(timings: false, ci: github));
    assert(masked.startsWith("::add-mask::hunter2\n"));
    assert(!masked.canFind("visible"), "only redacted values are masked");

    // A provider without masks never sees the value.
    assert(!transcript(g, run.events, PlainOptions(timings: false)).canFind("hunter2"));
}

// A graph with every output policy (TDO3): `a` and `b` show their tail only
// when they fail, `c` its last line when it succeeds, `d` nothing, and `e`,
// with a label, everything, one of its lines a two-line message.
version (unittest) private TaskGraph policyGraph() @safe pure nothrow
{
    auto nodes = [tnode("a"), tnode("b"), tnode("c"), tnode("d"), tnode("e")];
    nodes[0].outputPolicy = OutputPolicy.tailOnFailure;
    nodes[1].outputPolicy = OutputPolicy.tailOnFailure;
    nodes[2].outputPolicy = OutputPolicy.lastLineOnSuccess;
    nodes[3].outputPolicy = OutputPolicy.none;
    nodes[4].label = "the e";
    return graphOf(nodes, null);
}

version (unittest) private Script[string] policyScripts(const(int)[] durations) @safe pure nothrow
    => [
        "a": Script(durations[0].msecs, lines: ["a deprecation", "a note"]),
        "b": Script(durations[1].msecs, TaskOutcome(Failed(FailureReason.exitStatus, 1)), ["b noise", "b error"]),
        "c": Script(durations[2].msecs, lines: ["✓ c.one", "Summary: 1 passed"]),
        "d": Script(durations[3].msecs, lines: ["d chatter"]),
        "e": Script(durations[4].msecs, lines: ["one\ntwo"]),
    ];

@("build_primitives.task.reporter_plain.outputPolicies")
@system
unittest
{
    const g = policyGraph();
    enum expected =
        "a: succeeded\n"
        ~ "[b stdout] b noise\n"
        ~ "[b stdout] b error\n"
        ~ "b: failed: exit-status 1\n"
        ~ "[c stdout] Summary: 1 passed\n"
        ~ "c: succeeded\n"
        ~ "d: succeeded\n"
        ~ "[the e stdout] one\n"
        ~ "[the e stdout] two\n"
        ~ "the e: succeeded\n"
        ~ "summary: 5 tasks: 4 succeeded, 1 failed, 0 degraded, 0 skipped, 0 blocked, 0 unneeded, 0 cancelled\n"
        ~ "failed: b\n"
        ~ "exit: 1\n";
    foreach (durations; permutations([1, 2, 3, 4, 5]))
    {
        auto run = runFake(g, policyScripts(durations), ExecutorOptions(capacity: 3));
        const text = transcript(g, run.events, PlainOptions(timings: false));
        assert(text == expected, text);
    }
}

@("build_primitives.task.reporter_plain.interlacedStreamsOnlyReplayedNodes")
@system
unittest
{
    const g = policyGraph();
    auto run = runFake(g, policyScripts([1, 2, 3, 4, 5]), ExecutorOptions(capacity: 1));
    const text = transcript(g, run.events, PlainOptions(interlaced: true, timings: false));
    // Only `e`, a `replay` node, streams; the rest are written once
    // terminal: `c`'s last line with its result, `b`'s tail as a failure.
    assert(text ==
        "[the e stdout] one\n"
        ~ "[the e stdout] two\n"
        ~ "a: succeeded\n"
        ~ "b: failed: exit-status 1\n"
        ~ "[c stdout] Summary: 1 passed\n"
        ~ "c: succeeded\n"
        ~ "d: succeeded\n"
        ~ "the e: succeeded\n"
        ~ "failure b: failed: exit-status 1\n"
        ~ "[b stdout] b noise\n"
        ~ "[b stdout] b error\n"
        ~ "summary: 5 tasks: 4 succeeded, 1 failed, 0 degraded, 0 skipped, 0 blocked, 0 unneeded, 0 cancelled\n"
        ~ "failed: b\n"
        ~ "exit: 1\n", text);
}

// TDM21: a driver's notices show whatever the node's policy, after the lines
// the policy shows: `a` succeeds quietly, `b` fails with its tail, `d` shows
// nothing of its own, and `the e` is labelled; whatever the completion order.
@("build_primitives.task.reporter_plain.noticesShowWhateverThePolicy")
@system
unittest
{
    Script[string] withNotices(const(int)[] durations)
    {
        auto scripts = policyScripts(durations);
        scripts["a"].notices = ["not published: cannot publish the entry"];
        scripts["b"].notices = ["two\nlines"];
        scripts["d"].notices = ["unstable input: a.d changed while the compiler ran"];
        scripts["e"].notices = ["nondeterministic: e differs"];
        return scripts;
    }

    const g = policyGraph();
    enum expected =
        "[a notice] not published: cannot publish the entry\n"
        ~ "a: succeeded\n"
        ~ "[b stdout] b noise\n"
        ~ "[b stdout] b error\n"
        ~ "[b notice] two\n"
        ~ "[b notice] lines\n"
        ~ "b: failed: exit-status 1\n"
        ~ "[c stdout] Summary: 1 passed\n"
        ~ "c: succeeded\n"
        ~ "[d notice] unstable input: a.d changed while the compiler ran\n"
        ~ "d: succeeded\n"
        ~ "[the e stdout] one\n"
        ~ "[the e stdout] two\n"
        ~ "[the e notice] nondeterministic: e differs\n"
        ~ "the e: succeeded\n"
        ~ "summary: 5 tasks: 4 succeeded, 1 failed, 0 degraded, 0 skipped, 0 blocked, 0 unneeded, 0 cancelled\n"
        ~ "failed: b\n"
        ~ "exit: 1\n";
    foreach (durations; permutations([1, 2, 3, 4, 5]))
    {
        auto run = runFake(g, withNotices(durations), ExecutorOptions(capacity: 3));
        const text = transcript(g, run.events, PlainOptions(timings: false));
        assert(text == expected, text);
    }
    // Interlaced, a notice streams as it arrives: `a`'s, the first task's,
    // comes before any terminal line.
    auto run = runFake(g, withNotices([1, 2, 3, 4, 5]), ExecutorOptions(capacity: 1));
    const interlaced = transcript(g, run.events, PlainOptions(interlaced: true, timings: false));
    assert(interlaced.startsWith("[a notice] not published: cannot publish the entry\n"), interlaced);
}
