/++
A live view beside the plain transcript ([SPEC TDO2](../../../../../../docs/specs/build-primitives/task-dag/SPEC.md)).

A command that writes to a terminal keeps the plain reporter's transcript and
adds a view that redraws in place beneath it: the transcript's lines scroll
above the view as the plain reporter releases them, so what stays in the
scrollback is exactly what a non-terminal run writes. The view itself is the
consumer's ($(LREF LiveView)), because it depends on a UI library this package
does not import.

$(LREF WithLiveView) is the reporter that drives both: each event goes to the
transcript first and then to the view, and `finish` ends the transcript before
the view, so the view is gone only after the summary is above it.
+/
module sparkles.build_primitives.task.live_view;

import sparkles.build_primitives.task.model : TaskEvent;
import sparkles.build_primitives.task.reporter : isReporter;

/**
What a live view is told. One reporter fiber calls it, and a tick between
events comes from a fiber of the same scheduler, so no call overlaps another
(TDO1).
*/
interface LiveView
{
    /// Every event, after the transcript has seen it.
    void onEvent(const ref TaskEvent e);

    /// A complete transcript line, without its terminator, to print above the
    /// view.
    void printAbove(scope const(char)[] line);

    /// Redraws between events, so running times and spinners move; a no-op
    /// once finished.
    void tick();

    /// Ends the view after the transcript's last line, restoring the terminal.
    void finish();
}

/// A writer that hands each complete line to a $(LREF LiveView): the
/// transcript's sink under a live view. `flush` sends a final unterminated
/// line.
struct TranscriptLines
{
    LiveView view; ///
    private char[] pending;

    /// Writes `c`.
    void put(char c)
    {
        if (c == '\n')
        {
            view.printAbove(pending);
            pending.length = 0;
        }
        else
            pending ~= c;
    }

    /// Writes `text`.
    void put(scope const(char)[] text)
    {
        foreach (c; text)
            put(c);
    }

    /// Sends what remains of an unterminated last line.
    void flush()
    {
        if (pending.length)
            put('\n');
    }
}

/// The reporter that drives a transcript reporter and a live view together.
struct WithLiveView(R)
if (isReporter!R)
{
    R* transcript;          ///
    TranscriptLines* lines; /// the transcript's writer
    LiveView view;          ///

    /// Hands `e` to the transcript, then to the view.
    void onEvent(const ref TaskEvent e)
    {
        transcript.onEvent(e);
        view.onEvent(e);
    }

    /// Ends the transcript, then the view.
    void finish()
    {
        transcript.finish();
        lines.flush();
        view.finish();
    }
}

/**
A transcript the consumer draws itself (TDO9), in place of the plain one: it
sees every event and writes where it chooses — `ci` through its console, in
its line form. A live view, when there is one, sees each event after it.
*/
interface Transcript
{
    /// Every event, in order.
    void onEvent(const ref TaskEvent e);

    /// The run is over: the last lines, the summary.
    void finish();
}

/// The reporter that drives a consumer's 100 1 17 20 59 62 67 100 131 979 982 983 985 986 987 988 990 996LREF Transcript) and, when not
/// null, a live view after it.
struct TranscriptAndView
{
    Transcript transcript; ///
    LiveView view;         /// or null

    /// Hands `e` to the transcript, then to the view.
    void onEvent(const ref TaskEvent e)
    {
        transcript.onEvent(e);
        if (view !is null)
            view.onEvent(e);
    }

    /// Ends the transcript, then the view.
    void finish()
    {
        transcript.finish();
        if (view !is null)
            view.finish();
    }
}

static assert(isReporter!TranscriptAndView);

version (unittest)
{
    import sparkles.build_primitives.task.model : TaskFinished;

    private final class RecordingView : LiveView
    {
        string[] calls;
        override void onEvent(const ref TaskEvent e)
        {
            import std.sumtype : match;

            e.payload.match!((const TaskFinished _) { calls ~= "finished"; }, (_) {});
        }

        override void printAbove(scope const(char)[] line) { calls ~= "above " ~ line.idup; }
        override void tick() {}
        override void finish() { calls ~= "finish"; }
    }
}

/// The transcript reaches the view line by line, unchanged, and the view ends
/// after its last line.
@("build_primitives.task.live_view.transcriptScrollsAboveTheView")
@system
unittest
{
    import core.time : msecs;
    import std.algorithm.searching : countUntil, startsWith;
    import std.array : appender, join;
    import sparkles.build_primitives.task.executor : ExecutorOptions;
    import sparkles.build_primitives.task.model : FailureReason, Failed, TaskOutcome;
    import sparkles.build_primitives.task.reporter_plain : PlainOptions, PlainReporter;
    import sparkles.build_primitives.task.testing : graphOf, runFake, Script, tnode;

    const g = graphOf([tnode("a"), tnode("b")], null);
    auto run = runFake(g, ["a": Script(2.msecs, lines: ["hello"]),
        "b": Script(1.msecs, TaskOutcome(Failed(FailureReason.exitStatus, 2)), ["bad"])],
        ExecutorOptions(capacity: 2));

    auto plainOut = appender!string;
    auto plain = PlainReporter!(typeof(plainOut))(&plainOut, &g, PlainOptions(timings: false));
    foreach (ref e; run.events)
        plain.onEvent(e);
    plain.finish();

    auto view = new RecordingView;
    auto lines = TranscriptLines(view);
    auto transcript = PlainReporter!TranscriptLines(&lines, &g, PlainOptions(timings: false));
    auto both = WithLiveView!(typeof(transcript))(&transcript, &lines, view);
    foreach (ref e; run.events)
        both.onEvent(e);
    both.finish();

    string[] above;
    foreach (c; view.calls)
        if (c.startsWith("above "))
            above ~= c["above ".length .. $];
    assert(above.join("\n") ~ "\n" == plainOut[], "the scrollback is the plain transcript");
    assert(view.calls[$ - 1] == "finish");
    assert(view.calls.countUntil("finished") < view.calls.countUntil("above exit: 1"),
        "events reach the view as they come");
}

/// A consumer's transcript sees each event before the view, and ends first
/// (TDO9); without a view, it runs alone.
@("build_primitives.task.live_view.transcriptThenView")
@system
unittest
{
    import core.time : MonoTime;
    import sparkles.build_primitives.task.model : RunFinished, TaskEventPayload;

    static final class Log : Transcript
    {
        string[]* calls;
        this(string[]* calls) { this.calls = calls; }
        override void onEvent(const ref TaskEvent e) { *calls ~= "transcript"; }
        override void finish() { *calls ~= "transcript finish"; }
    }

    // One log for both, so their order shows.
    auto view = new RecordingView;
    auto both = TranscriptAndView(new Log(&view.calls), view);
    auto e = TaskEvent(0, MonoTime.init, TaskEventPayload(RunFinished(0)));
    both.onEvent(e);
    both.finish();
    assert(view.calls == ["transcript", "transcript finish", "finish"]);

    string[] calls;
    auto alone = TranscriptAndView(new Log(&calls), null);
    alone.onEvent(e);
    alone.finish();
    assert(calls == ["transcript", "transcript finish"]);
}
