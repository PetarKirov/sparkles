/++
`ci test`'s live view ([SPEC TDO8](../../../../docs/specs/build-primitives/task-dag/SPEC.md)):
a block redrawn beneath the plain transcript while the build graph runs, in
the spirit of nix-output-monitor and bootvine.

From top to bottom:

$(OL
    $(LI $(B the tree) of the tasks still to finish, each under the task
        waiting on it: failures first, then the longest-running, then the
        rest, fitted to its rows (`fitTree`: straight chains fold into one
        row, and past the room only the paths to running and failed tasks
        stay, with a count of the others);)
    $(LI $(B the failures), newest first: the task, why it failed and its
        last lines; older ones shrink to their headline when rows run out;)
    $(LI $(B the timeline), in the rows left and when the terminal is wide
        enough, unless turned off: the slowest finished tasks and the
        running ones as bars against the run's elapsed time;)
    $(LI $(B the tally): running, executed, reused from the store, pending
        and failed, and the elapsed time.)
)

The block is `sparkles:ui` widgets — the tree, the timeline's fill spans —
laid out at the terminal's width and painted by its own canvas
(`inlineFrame`), in its 16 colours. The transcript's lines print above it as
the plain reporter releases them, so what stays in the scrollback is the
transcript alone; `finish` erases the block once the summary is above it.
+/
module task.reporter_live;

import core.time : Duration, MonoTime, msecs, seconds;

import std.algorithm.comparison : max, min;
import std.algorithm.sorting : sort;
import std.array : appender, join;
import std.sumtype : match;

import sparkles.base.text.writers : writeDuration;
import sparkles.ui.components.live : LiveRegion;
import sparkles.ui.components.timeline : TimelineBar, timelineView;
import sparkles.ui.components.tree_fit : fitTree;
import sparkles.ui.components.tree_widget : flatten, TreeData, TreeGlyphs, treeView;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.glyphs : Mark, markGlyph;
import sparkles.ui.style : MarkCharset, Slot;
import sparkles.ui.tokens : TargetCapabilities;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;
import sparkles.ui_tui.inline_frame : inlineFrame;

import sparkles.build_primitives.task.graph : TaskGraph;
import sparkles.build_primitives.task.live_view : LiveView;
import console : drainConsole, holdConsole, releaseConsole;
import sparkles.build_primitives.task.model;
import sparkles.build_primitives.task.reporter : writeOutcome;
import task.reporter_status : taskName;

/// What the live view shows.
struct LiveOptions
{
    /// Draw the timeline when the rows and the width allow it.
    bool timeline = true;
    /// How long a finished task stays in the tree.
    Duration keepFinished = 2.seconds;
    /// Output lines kept for a failure's entry.
    size_t failureLines = 6;
    /// Finished tasks the timeline shows, slowest first.
    size_t slowest = 5;
    /// Finished tasks shorter than this stay off the timeline.
    Duration shortest = 1.seconds;
}

/// The terminal the view is drawn on: its size, re-read every frame, and
/// what it can draw.
struct LiveTerminal
{
    ushort delegate() @safe width;  ///
    ushort delegate() @safe height; ///
    TargetCapabilities caps;        ///
}

/// The fewest columns the timeline needs: a label, a bar and a length.
enum int timelineMinWidth = 50;

/// The rows of the body each part takes (bootvine's order): failures keep a
/// few rows beside a full tree, the tree takes what it needs of the rest, and
/// the timeline only what is left, when that is enough to read.
struct Heights
{
    int tree;     ///
    int failures; ///
    int timeline; ///

    /// Shares `free` rows.
    static Heights share(int free, int treeNeed, int failuresNeed, int timelineNeed) @safe pure nothrow @nogc
    {
        enum int panelMinimum = 3;
        free = max(free, 0);
        int failures = min(failuresNeed, max(0, free - treeNeed));
        if (failuresNeed > 0)
            failures = max(failures, min(failuresNeed, panelMinimum, free));
        const tree = min(treeNeed, free - failures);
        const left = free - failures - tree;
        const timeline = timelineNeed > 0 && left >= panelMinimum ? min(timelineNeed, left) : 0;
        return Heights(tree, failures, timeline);
    }
}

/// The live view; see the module documentation.
final class LiveReporter : LiveView
{
    /// Draws in `region` (owned by the caller) on `terminal`.
    this(LiveRegion* region, const(TaskGraph)* graph, LiveTerminal terminal, LiveOptions options,
        MonoTime delegate() @safe clock = null)
    {
        this.region = region;
        this.graph = graph;
        this.terminal = terminal;
        this.options = options;
        this.clock = clock !is null ? clock : () @safe => MonoTime.currTime;
        tasks = new TaskState[graph.nodes.length];
        runStart = this.clock();
    }

    override void onEvent(const ref TaskEvent e)
    {
        e.payload.match!(
            (const TaskStarted s) {
                auto t = &tasks[s.task.value];
                t.phase = Phase.running;
                t.started = e.at;
            },
            (const TaskOutput o) {
                auto t = &tasks[o.task.value];
                t.tail ~= e.text;
                if (t.tail.length > options.failureLines)
                    t.tail = t.tail[$ - options.failureLines .. $];
            },
            (const TaskReused r) { tasks[r.task.value].reused = true; },
            (const TaskFinished f) { finished(f, e.at); },
            (_) {},
        );
    }

    override void printAbove(scope const(char)[] line)
    {
        above ~= line.idup;
    }

    override void tick()
    {
        if (!ended)
            paint();
    }

    override void finish()
    {
        if (ended)
            return;
        ended = true;
        // The console writes for itself again once the block is gone.
        releaseConsole((scope const(char)[] l) @safe { above ~= l.idup; });
        region.printLinesAbove(above);
        above = null;
        region.finish(keepFrame: false);
    }

    /// The block as widgets, `width` columns wide and at most `rows` tall, at
    /// `now`.
    WidgetTree frame(int width, int rows, MonoTime now)
    {
        Builder b;
        uint[] parts;

        const timelineRoom = options.timeline && width >= timelineMinWidth;
        auto bars = timelineRoom ? timelineBars(now) : null;
        auto failures = failedNewestFirst();
        auto full = buildTree(now);
        const treeNeed = cast(int) full.nodes.length;
        const failuresNeed = failures.length
            ? cast(int)(1 + failures.length + tasks[failures[0]].tail.length) : 0;
        const timelineNeed = bars.length ? cast(int) bars.length + 1 : 0;
        const h = Heights.share(rows - 1, treeNeed, failuresNeed, timelineNeed);

        if (h.tree > 0)
            parts ~= treeRows(b, full, h.tree);
        if (h.failures > 0)
            parts ~= failureRows(b, failures, h.failures);
        if (h.timeline > 0)
            parts ~= timelineRows(b, bars, h.timeline, width, now);
        parts ~= b.add(Widget(kind: WidgetKind.rich, spans: tally(now)));
        return b.finish(b.add(Widget(kind: WidgetKind.column, width: SizeSpec.grow(), children: parts)));
    }

private:
    enum Phase : ubyte { pending, running, done, failed }

    struct TaskState
    {
        Phase phase;
        bool reused;
        bool blocked;    // ended without running because something failed
        MonoTime started;
        MonoTime ended;
        string[] tail;   // the last lines, for a failure's entry
        string reason;   // why it failed
    }

    struct Row
    {
        const(char)[] label;
        const(char)[] icon;
        Slot slot = Slot.inherit;
        const(char)[] badge;
        Slot badgeSlot = Slot.muted;
        Slot iconSlot = Slot.muted;
        enum badgeRight = true;
        bool anchor;
        bool chainLink;
        const(char)[][] chain;
    }

    LiveRegion* region;
    const(TaskGraph)* graph;
    LiveTerminal terminal;
    LiveOptions options;
    MonoTime delegate() @safe clock;
    TaskState[] tasks;
    MonoTime runStart;
    size_t[] failureOrder; // task indices, in the order they failed
    string[] above;
    bool ended;
    size_t executed, reused, failedCount;

    void finished(const TaskFinished f, MonoTime at)
    {
        const i = f.task.value;
        auto t = &tasks[i];
        t.ended = at;
        if (t.phase != Phase.running)
            t.started = at;
        final switch (kindOf(f.outcome))
        {
            case OutcomeKind.failed:
                t.phase = Phase.failed;
                auto w = appender!string;
                writeOutcome(w, *graph, f.outcome);
                t.reason = w[];
                failureOrder ~= i;
                ++failedCount;
                return;
            case OutcomeKind.blocked:
                t.blocked = failsCommand(f.outcome);
                break;
            case OutcomeKind.succeeded, OutcomeKind.degraded, OutcomeKind.skipped,
                    OutcomeKind.cancelled:
                break;
        }
        const ran = t.phase == Phase.running;
        t.phase = Phase.done;
        t.tail = null;
        if (ran && t.reused)
            ++reused;
        else if (ran)
            ++executed;
    }

    void paint()
    {
        // The console's lines, held while the block is up (CIC19).
        drainConsole((scope const(char)[] l) @safe { above ~= l.idup; });
        const width = max(20, terminal.width() - 1);
        const height = terminal.height();
        const rows = height > 0 ? max(6, height * 2 / 3) : 20;
        auto lines = inlineFrame(frame(width, rows, clock()), width, terminal.caps);
        if (above.length)
        {
            region.printLinesAbove(above);
            above = null;
        }
        region.update(lines);
    }

    string mark(Mark m) const
    {
        import std.conv : to;

        return markGlyph(m, MarkCharset.unicode, terminal.caps).to!string ~ " ";
    }

    // Whether task `i` is in the tree: it has yet to finish, it failed, or
    // it ran and finished a moment ago.
    bool shown(size_t i, MonoTime now) const
    {
        const t = &tasks[i];
        final switch (t.phase)
        {
            case Phase.pending, Phase.running, Phase.failed:
                return true;
            case Phase.done:
                return !t.reused && !t.blocked && t.started != t.ended
                    && now - t.ended <= options.keepFinished;
        }
    }

    // A task's place among its siblings: failures first, earliest first;
    // then running tasks, longest first; then those that just finished; then
    // the pending; ties in presentation order. A subtree ranks as its best.
    static struct Rank
    {
        ubyte cls;
        long key;
        uint index;

        int opCmp(in Rank r) const @safe pure nothrow @nogc
        {
            if (cls != r.cls)
                return cls < r.cls ? -1 : 1;
            if (key != r.key)
                return key < r.key ? -1 : 1;
            return index < r.index ? -1 : index > r.index ? 1 : 0;
        }
    }

    Rank ownRank(size_t i) const
    {
        const t = &tasks[i];
        final switch (t.phase)
        {
            case Phase.failed: return Rank(0, t.ended.ticks, cast(uint) i);
            case Phase.running: return Rank(1, t.started.ticks, cast(uint) i);
            case Phase.done: return Rank(2, -t.ended.ticks, cast(uint) i);
            case Phase.pending: return Rank(3, 0, cast(uint) i);
        }
    }

    TreeData!Row buildTree(MonoTime now)
    {
        const n = tasks.length;
        auto isShown = new bool[n];
        foreach (i; 0 .. n)
            isShown[i] = shown(i, now);
        auto best = new Rank[n];
        auto ranked = new bool[n];
        Rank rankOf(size_t i)
        {
            if (ranked[i])
                return best[i];
            Rank r = ownRank(i);
            foreach (e; graph.incoming(TaskIndex(cast(uint) i)))
                if (isShown[e.prerequisite.value])
                {
                    const c = rankOf(e.prerequisite.value);
                    if (c < r)
                        r = c;
                }
            ranked[i] = true;
            return best[i] = r;
        }

        size_t[] roots;
        foreach (i; 0 .. n)
        {
            if (!isShown[i])
                continue;
            bool waitedOn;
            foreach (e; graph.outgoing(TaskIndex(cast(uint) i)))
                if (isShown[e.dependent.value])
                    waitedOn = true;
            if (!waitedOn)
                roots ~= i;
        }
        roots.sort!((a, b) => rankOf(a) < rankOf(b));

        TreeData!Row data;
        auto placed = new bool[n];
        void place(size_t i, uint parent)
        {
            placed[i] = true;
            const at = data.add(row(i, now), parent);
            size_t[] children;
            foreach (e; graph.incoming(TaskIndex(cast(uint) i)))
                if (isShown[e.prerequisite.value] && !placed[e.prerequisite.value])
                    children ~= e.prerequisite.value;
            children.sort!((a, b) => rankOf(a) < rankOf(b));
            foreach (c; children)
                if (!placed[c])
                    place(c, at);
        }

        foreach (r; roots)
            if (!placed[r])
                place(r, uint.max);
        return data;
    }

    Row row(size_t i, MonoTime now)
    {
        const t = &tasks[i];
        const label = taskName(*graph, TaskIndex(cast(uint) i));
        final switch (t.phase)
        {
            case Phase.running:
                const ran = now - t.started;
                return Row(label, mark(Mark.running), Slot.inherit,
                    ran >= 1.seconds ? duration(ran) : null, iconSlot: Slot.accentPrimary, anchor: true);
            case Phase.failed:
                return Row(label, mark(Mark.fail), Slot.error, duration(t.ended - t.started),
                    Slot.error, iconSlot: Slot.error, anchor: true);
            case Phase.done:
                return Row(label, mark(Mark.ok), Slot.muted, duration(t.ended - t.started),
                    iconSlot: Slot.success);
            case Phase.pending:
                return Row(label, mark(Mark.pending), Slot.muted, chainLink: true);
        }
    }

    uint treeRows(ref Builder b, TreeData!Row full, int rows)
    {
        auto fitted = fitTree(full, rows);
        foreach (ref node; fitted.data.nodes)
            if (node.value.chain.length)
                node.value.label = ([node.value.label] ~ node.value.chain).join(" ─ ");
        auto glyphs = TreeGlyphs.init;
        glyphs.closed = glyphs.open = glyphs.leaf = "";
        // Roots stand flush left: only a task waiting on another hangs from it.
        auto flat = flatten(fitted.data, (uint _) @safe => true);
        foreach (ref r; flat)
            r.guides = r.guides[1 .. $];
        const tree = treeView(b, fitted.data, flat,
            (uint _) @safe => true, uint.max, glyphs);
        if (!fitted.hidden)
            return tree;
        auto more = appender!string;
        more.put("… ");
        writeDecimal(more, fitted.hidden);
        more.put(fitted.hidden == 1 ? " more task" : " more tasks");
        const count = b.add(Widget(kind: WidgetKind.text, text: more[], slot: Slot.muted));
        return b.add(Widget(kind: WidgetKind.column, width: SizeSpec.grow(), children: [tree, count]));
    }

    size_t[] failedNewestFirst() const
    {
        size_t[] order;
        foreach_reverse (i; failureOrder)
            order ~= i;
        return order;
    }

    // The failures, newest first, in `rows`: a header, then each headline;
    // the newest keeps its last lines while there is room, and a last row
    // counts what does not fit.
    uint failureRows(ref Builder b, size_t[] failures, int rows)
    {
        uint[] lines;
        auto header = appender!string;
        header.put("Failures (");
        writeDecimal(header, failures.length);
        header.put(")");
        lines ~= b.add(Widget(kind: WidgetKind.text, text: header[], slot: Slot.error));
        int left = rows - 1;
        foreach (n, i; failures)
        {
            const rest = failures.length - n;
            if (left <= 0 || (left == 1 && rest > 1))
            {
                auto more = appender!string;
                more.put("… ");
                writeDecimal(more, rest);
                more.put(" more");
                lines ~= b.add(Widget(kind: WidgetKind.text, text: more[], slot: Slot.muted));
                break;
            }
            const t = &tasks[i];
            lines ~= b.add(Widget(kind: WidgetKind.rich, spans: [
                TextSpan(mark(Mark.fail), Slot.error),
                TextSpan(taskName(*graph, TaskIndex(cast(uint) i)), Slot.inherit),
                TextSpan(": ", Slot.muted),
                TextSpan(t.reason, Slot.muted),
            ]));
            --left;
            if (n == 0)
            {
                // Keep a row for the count when older failures follow.
                const room = left - (failures.length > 1 ? 1 : 0);
                const from = t.tail.length > room ? t.tail.length - max(room, 0) : 0;
                foreach (line; t.tail[from .. $])
                {
                    lines ~= b.add(Widget(kind: WidgetKind.text, text: "  " ~ line, slot: Slot.muted));
                    --left;
                }
            }
        }
        return b.add(Widget(kind: WidgetKind.column, width: SizeSpec.grow(), children: lines));
    }

    // The slowest finished executed tasks, then the running ones.
    TimelineBar[] timelineBars(MonoTime now)
    {
        static struct Run { size_t task; Duration took; }
        Run[] runs;
        foreach (i, ref t; tasks)
            if ((t.phase == Phase.done || t.phase == Phase.failed) && !t.reused && !t.blocked
                    && t.ended - t.started >= options.shortest)
                runs ~= Run(i, t.ended - t.started);
        runs.sort!((a, b) => a.took > b.took || (a.took == b.took && a.task < b.task));
        if (runs.length > options.slowest)
            runs = runs[0 .. options.slowest];
        TimelineBar[] bars;
        foreach (ref r; runs)
        {
            const t = &tasks[r.task];
            bars ~= TimelineBar(taskName(*graph, TaskIndex(cast(uint) r.task)),
                t.started - runStart, t.ended - runStart,
                t.phase == Phase.failed ? Slot.error : Slot.info);
        }
        foreach (i, ref t; tasks)
            if (t.phase == Phase.running && now - t.started >= options.shortest)
                bars ~= TimelineBar(taskName(*graph, TaskIndex(cast(uint) i)),
                    t.started - runStart, now - runStart, Slot.accentPrimary);
        bars.sort!((a, b) => a.start < b.start);
        return bars;
    }

    uint timelineRows(ref Builder b, TimelineBar[] bars, int rows, int width, MonoTime now)
    {
        if (bars.length > rows - 1)
            bars = bars[0 .. rows - 1];
        // A round axis that grows in steps, so a running bar grows to the
        // right and the scale moves only when the run passes a step.
        const axis = roundAxis(now - runStart);
        auto header = appender!string;
        header.put("Slowest tasks, from the start to ");
        writeDuration(header, axis);
        const title = b.add(Widget(kind: WidgetKind.text, text: header[], slot: Slot.muted));
        const view = timelineView(b, bars, axis, min(32, width / 3));
        return b.add(Widget(kind: WidgetKind.column, width: SizeSpec.grow(), children: [title, view]));
    }

    TextSpan[] tally(MonoTime now)
    {
        size_t running, pending;
        foreach (ref t; tasks)
            if (t.phase == Phase.running)
                ++running;
            else if (t.phase == Phase.pending)
                ++pending;
        TextSpan[] spans;
        void count(Mark m, size_t n, string what, Slot slot)
        {
            auto w = appender!string;
            if (spans.length)
                w.put("  ");
            w.put(mark(m));
            writeDecimal(w, n);
            w.put(" ");
            w.put(what);
            spans ~= TextSpan(w[], n ? slot : Slot.muted);
        }

        count(Mark.running, running, "running", Slot.accentPrimary);
        count(Mark.ok, executed, "executed", Slot.success);
        count(Mark.info, reused, "from the store", Slot.muted);
        count(Mark.pending, pending, "pending", Slot.muted);
        count(Mark.fail, failedCount, "failed", Slot.error);
        spans ~= TextSpan("  " ~ duration(now - runStart), Slot.muted);
        return spans;
    }
}

/**
Whether a run reports through the live view: when asked (`forced`), or by
default when stdout is a terminal and the run is not under a CI service,
unless refused.
*/
bool liveViewWanted(bool forced, bool refused, bool stdoutIsTerminal, bool underCi)
    @safe pure nothrow @nogc
    => forced || (!refused && stdoutIsTerminal && !underCi);

///
@("task.reporter_live.liveViewWanted")
@safe pure nothrow @nogc unittest
{
    assert(liveViewWanted(false, false, true, false));
    assert(!liveViewWanted(false, false, false, false), "not on a pipe");
    assert(!liveViewWanted(false, false, true, true), "not under CI");
    assert(!liveViewWanted(false, true, true, false), "not when refused");
    assert(liveViewWanted(true, false, false, true), "always when asked");
}

/**
The `RunReporting.live` factory for a run on stdout: once the graph is
built, a live region on stdout and the view drawn in it, at the terminal's
size and with its capabilities.
*/
LiveView delegate(const(TaskGraph)*) stdoutLiveView(LiveOptions options)
{
    return (const(TaskGraph)* graph) {
        import std.stdio : stdout;
        import sparkles.base.term_caps : detectTermCaps, terminalSize;
        import sparkles.ui.tokens : terminalCapabilities;

        holdConsole();
        auto region = new LiveRegion((scope const(char)[] bytes) {
            stdout.rawWrite(bytes);
            stdout.flush();
        }, () => terminalSize().width, true);
        const terminal = LiveTerminal(() @safe => terminalSize().width,
            () @safe => terminalSize().height, terminalCapabilities(detectTermCaps()));
        return cast(LiveView) new LiveReporter(region, graph, terminal, options);
    };
}

/**
The timeline's axis for a run `elapsed` long: the first of 10s, 20s, 30s,
1m, 2m, 3m, 5m, 10m, 15m, 20m, 30m, 1h, then whole hours, that is not
shorter.
*/
Duration roundAxis(Duration elapsed) @safe pure nothrow @nogc
{
    import core.time : hours, minutes;

    static immutable Duration[12] steps = [10.seconds, 20.seconds, 30.seconds, 1.minutes, 2.minutes,
        3.minutes, 5.minutes, 10.minutes, 15.minutes, 20.minutes, 30.minutes, 1.hours];
    foreach (s; steps)
        if (elapsed <= s)
            return s;
    return (elapsed.total!"hours" + (elapsed > elapsed.total!"hours".hours ? 1 : 0)).hours;
}

/// The axis is the first round step the run has not passed.
@("task.reporter_live.roundAxis.stepsTheRunHasNotPassed")
@safe pure nothrow @nogc unittest
{
    import core.time : hours, minutes;

    assert(roundAxis(Duration.zero) == 10.seconds);
    assert(roundAxis(55.seconds) == 1.minutes);
    assert(roundAxis(61.seconds) == 2.minutes);
    assert(roundAxis(2.hours + 1.seconds) == 3.hours);
}

private string duration(Duration d)
{
    auto w = appender!string;
    writeDuration(w, d);
    return w[];
}

private void writeDecimal(W)(ref W w, size_t n)
{
    import sparkles.base.text.writers : writeInteger;

    writeInteger(w, n);
}

version (unittest)
{
    import sparkles.ui.tokens : capabilitiesOf, Profile;
    import sparkles.build_primitives.task.testing : graphOf, tedge, tnode;

    // A graph a test drives by hand: `test` waits on `link`, which waits on
    // `compile-a` and `compile-b`; `other` stands alone.
    TaskGraph sampleGraph()
        => graphOf([tnode("compile-a"), tnode("compile-b"), tnode("link"), tnode("test"),
            tnode("other")],
            [tedge("compile-a", "link"), tedge("compile-b", "link"), tedge("link", "test")]);

    struct Harness
    {
        TaskGraph graph;
        LiveRegion* region;
        LiveReporter view;
        MonoTime now;
        string bytes;
        ulong seq;

        static Harness make(LiveOptions options = LiveOptions.init)
        {
            Harness h;
            h.graph = sampleGraph();
            h.now = MonoTime.zero + 1.seconds;
            return h;
        }

        void start(LiveOptions options = LiveOptions.init)
        {
            region = new LiveRegion((scope const(char)[] b) { bytes ~= b; }, () => ushort(80), true);
            auto caps = capabilitiesOf(Profile.enhanced);
            view = new LiveReporter(region, &graph,
                LiveTerminal(() @safe => ushort(81), () @safe => ushort(30), caps), options,
                () @safe => now);
        }

        void event(TaskEventPayload p, string text = null)
        {
            auto e = TaskEvent(seq++, now, p, text);
            view.onEvent(e);
        }

        TaskIndex at(string id) => graph.indexOf(taskId(id).value);

        string[] screen(int rows = 20)
        {
            import sparkles.base.term_color : ColorDepth;
            import sparkles.ui_tui.grid_canvas : gridCapabilities;

            auto plain = gridCapabilities;
            plain.output.colorDepth = ColorDepth.none;
            return inlineFrame(view.frame(80, rows, now), 80, plain);
        }
    }
}

/// Failures keep rows beside a full tree; the timeline takes only what is
/// left, and only enough to read.
@("task.reporter_live.Heights.share")
@safe pure nothrow @nogc unittest
{
    assert(Heights.share(20, 8, 0, 6) == Heights(8, 0, 6));
    assert(Heights.share(20, 30, 0, 6) == Heights(20, 0, 0), "a full tree leaves no timeline");
    assert(Heights.share(20, 30, 9, 6) == Heights(17, 3, 0), "failures keep three rows");
    assert(Heights.share(20, 5, 9, 6) == Heights(5, 9, 6));
    assert(Heights.share(20, 15, 3, 6) == Heights(15, 3, 0), "two rows are too few for a timeline");
}

/// The tree nests each task under the one waiting on it, running tasks with
/// their time, and the tally counts each state.
@("task.reporter_live.frame.treeAndTally")
@system unittest
{
    import std.algorithm.searching : canFind, endsWith, startsWith;

    auto h = Harness.make();
    h.start();
    h.event(TaskEventPayload(TaskStarted(h.at("compile-a"))));
    h.now += 3.seconds;
    const lines = h.screen();
    const text = lines.join("\n");
    assert(lines.length >= 5, text);
    // The branch with the running task first, each task under the one
    // waiting on it, the running one with its time at the right edge; the
    // roots flush left, hanging from nothing.
    assert(lines[0] == "○ test" && lines[1] == "└─ ○ link", text);
    assert(lines[2].startsWith("   ├─ ◐ compile-a") && lines[2].endsWith("3.0s"), text);
    assert(lines[3] == "   └─ ○ compile-b" && lines[4] == "○ other", text);
    assert(lines[$ - 1].startsWith("◐ 1 running  ✔ 0 executed  • 0 from the store  ○ 4 pending  ✖ 0 failed"),
        lines[$ - 1]);

    // Out of rows, a chain of waiting tasks folds into one row.
    h.event(TaskEventPayload(TaskStarted(h.at("compile-b"))));
    h.event(TaskEventPayload(TaskReused(h.at("compile-b"))));
    h.event(TaskEventPayload(TaskFinished(h.at("compile-b"), TaskOutcome(Succeeded()), 1.msecs)));
    const short_ = h.screen(4);
    assert(short_[0] == "○ test ─ link", short_.join("\n"));
    assert(short_[1].startsWith("└─ ◐ compile-a"), short_.join("\n"));
}

/// A failure gets a panel entry with its reason and last lines; a reused
/// task counts apart from executed work and leaves the tree.
@("task.reporter_live.frame.failuresAndReuse")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto h = Harness.make();
    h.start();
    h.event(TaskEventPayload(TaskStarted(h.at("compile-a"))));
    h.event(TaskEventPayload(TaskReused(h.at("compile-a"))));
    h.event(TaskEventPayload(TaskFinished(h.at("compile-a"), TaskOutcome(Succeeded()), 1.msecs)));
    h.event(TaskEventPayload(TaskStarted(h.at("compile-b"))));
    h.event(TaskEventPayload(TaskOutput(h.at("compile-b"), OutputStream.stderr, 0, 0, false)),
        "b.d(3): Error: undefined identifier `x`");
    h.now += 2.seconds;
    h.event(TaskEventPayload(TaskFinished(h.at("compile-b"),
        TaskOutcome(Failed(FailureReason.exitStatus, 1)), 2.seconds)));
    const text = h.screen().join("\n");
    assert(text.canFind("Failures (1)"), text);
    assert(text.canFind("✖ compile-b: failed: exit-status 1"), text);
    assert(text.canFind("  b.d(3): Error: undefined identifier `x`"), text);
    assert(!text.canFind("compile-a"), "a reused task leaves the tree\n" ~ text);
    assert(text.canFind("1 from the store") && text.canFind("0 executed") && text.canFind("1 failed"), text);
}

/// The timeline shows the slowest finished tasks as fill spans, only when
/// it is wanted and there is room.
@("task.reporter_live.frame.timelineIsOptional")
@system unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.base.term_color : RgbColor;

    size_t spansIn(WidgetTree tree)
    {
        const ops = buildDisplayList(tree, layout(tree, Constraints(maxW: 80)),
            defaultTwoslashPalette(), RgbColor(0, 0, 0), RgbColor(255, 255, 255));
        size_t n;
        foreach (ref op; ops)
            n += op.kind == OpKind.fillSpan;
        return n;
    }

    foreach (wanted; [true, false])
    {
        auto h = Harness.make();
        h.start(LiveOptions(timeline: wanted));
        h.event(TaskEventPayload(TaskStarted(h.at("other"))));
        h.now += 4.seconds;
        h.event(TaskEventPayload(TaskFinished(h.at("other"), TaskOutcome(Succeeded()), 4.seconds)));
        h.now += 1.seconds;
        assert(spansIn(h.view.frame(80, 20, h.now)) == (wanted ? 1 : 0));
        assert(spansIn(h.view.frame(40, 20, h.now)) == 0, "too narrow for a timeline");
        assert(spansIn(h.view.frame(80, 6, h.now)) == 0, "too few rows for a timeline");
        assert(h.screen().join("\n").canFind("Slowest") == wanted);
    }
}

/// Transcript lines print above the block on the next repaint, and `finish`
/// prints what is left and erases the block.
@("task.reporter_live.finish.transcriptAboveAndBlockErased")
@system unittest
{
    import std.algorithm.searching : canFind, endsWith;
    import sparkles.base.term_control : CtlSeq;

    auto h = Harness.make();
    h.start();
    h.view.tick();
    h.view.printAbove("summary: 5 tasks");
    h.view.printAbove("exit: 0");
    h.view.finish();
    assert(h.bytes.canFind("summary: 5 tasks\nexit: 0\n"), h.bytes);
    assert(h.bytes.endsWith(cast(string) CtlSeq.showCursor), "the terminal is restored");
    h.view.tick(); // a late tick draws nothing
    assert(h.bytes.endsWith(cast(string) CtlSeq.showCursor));
}
