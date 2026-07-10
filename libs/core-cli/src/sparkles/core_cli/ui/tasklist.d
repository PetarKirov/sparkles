/++
A checklist of tasks driven through a $(REF LiveRegion, sparkles,core_cli,ui,live):
pending/running items are repainted in place, and each task that reaches a
terminal state (ok / failed / skipped) graduates as a permanent line into the
scrollback above — so on a tty the block shrinks as work completes, and on
piped output only the completed-task transitions appear, one line each.

`renderTaskLine`/`renderTaskList` are pure producers (unit-testable, theme-
driven); $(LREF TaskReporter) is the stateful driver the apps use.
+/
module sparkles.core_cli.ui.tasklist;

import core.time : Duration, MonoTime;

import sparkles.core_cli.ui.live : LiveRegion;
import sparkles.core_cli.ui.progress : spinnerFrame;
import sparkles.core_cli.ui.theme : Semantic, Theme;

/// The lifecycle of one task.
enum TaskStatus { pending, running, ok, failed, skipped }

/// One row of the checklist.
struct TaskItem
{
    string label;
    TaskStatus status;
    string detail;      /// Extra text after the label (rendered muted).
    size_t indent;      /// Nesting level (2 spaces each).
    Duration elapsed;   /// Shown as ` (…)` on terminal states when non-zero.
}

/// The status mark for `status`, themed (spinner frame for `running`).
string taskMark(const Theme theme, TaskStatus status, size_t spinnerStep = 0) @safe pure nothrow
{
    final switch (status)
    {
        case TaskStatus.pending: return theme.paint(Semantic.muted, theme.glyphs.pending);
        case TaskStatus.running: return theme.paint(Semantic.accent,
            theme.unicode ? spinnerFrame(spinnerStep) : theme.glyphs.running);
        case TaskStatus.ok:      return theme.paint(Semantic.success, theme.glyphs.ok);
        case TaskStatus.failed:  return theme.paint(Semantic.failure, theme.glyphs.fail);
        case TaskStatus.skipped: return theme.paint(Semantic.muted, theme.glyphs.skipped);
    }
}

/// One rendered checklist row: indent, mark, label, then muted detail and
/// elapsed time when present.
string renderTaskLine(in TaskItem item, const Theme theme, size_t spinnerStep = 0) @safe pure
{
    import std.array : appender;
    import std.range : repeat;
    import sparkles.base.text.writers : writeDuration;

    auto w = appender!string;
    foreach (_; 0 .. item.indent * 2)
        w.put(' ');
    w.put(taskMark(theme, item.status, spinnerStep));
    w.put(' ');
    w.put(item.label);
    if (item.detail.length)
    {
        w.put(' ');
        w.put(theme.paint(Semantic.muted, item.detail));
    }
    if (item.elapsed > Duration.zero)
    {
        auto t = appender!string;
        t.put(" (");
        writeDuration(t, item.elapsed);
        t.put(')');
        w.put(theme.paint(Semantic.muted, t[]));
    }
    return w[];
}

/// The live-frame rows: every item not yet in a terminal state (terminal items
/// live in the scrollback, printed by the reporter as they complete).
string[] renderTaskList(in TaskItem[] items, const Theme theme, size_t spinnerStep = 0) @safe pure
{
    string[] lines;
    foreach (ref item; items)
        if (item.status == TaskStatus.pending || item.status == TaskStatus.running)
            lines ~= renderTaskLine(item, theme, spinnerStep);
    return lines;
}

/// The stateful checklist driver. Owns the item states; each transition
/// repaints the live block and graduates finished tasks into the scrollback.
/// The `LiveRegion` stays owned by the caller (`scope (exit) region.finish();`).
struct TaskReporter
{
    private
    {
        LiveRegion* _region;
        Theme _theme;
        TaskItem[] _items;
        MonoTime[] _startedAt;
        size_t _spin;
    }

    this(LiveRegion* region, Theme theme)
    in (region !is null)
    {
        _region = region;
        _theme = theme;
    }

    /// Register a task (pending) and return its handle.
    size_t add(string label, size_t indent = 0)
    {
        _items ~= TaskItem(label: label, indent: indent);
        _startedAt ~= MonoTime.init;
        repaint();
        return _items.length - 1;
    }

    /// Mark `id` running (starts its clock) and repaint.
    void start(size_t id)
    in (id < _items.length)
    {
        _items[id].status = TaskStatus.running;
        _startedAt[id] = MonoTime.currTime;
        repaint();
    }

    /// Terminal transitions: the task's line graduates into the scrollback.
    /// A multi-line `detail` puts the first line on the task row and the rest
    /// as indented follow-up lines (e.g. a failure's output tail).
    void succeed(size_t id, string detail = null) { complete(id, TaskStatus.ok, detail); }
    /// ditto
    void fail(size_t id, string detail = null) { complete(id, TaskStatus.failed, detail); }
    /// ditto
    void skip(size_t id, string detail = null) { complete(id, TaskStatus.skipped, detail); }

    /// Advance the spinner (call from a periodic tick when one is available).
    void tick()
    {
        _spin++;
        repaint();
    }

    /// The items (for tests / summaries).
    const(TaskItem)[] items() const @safe pure nothrow @nogc => _items;

    private void complete(size_t id, TaskStatus status, string detail)
    in (id < _items.length)
    {
        import std.string : lineSplitter;
        import std.array : array;

        auto item = &_items[id];
        item.status = status;
        if (_startedAt[id] != MonoTime.init)
            item.elapsed = MonoTime.currTime - _startedAt[id];

        auto detailLines = detail.lineSplitter.array;
        item.detail = detailLines.length ? detailLines[0] : null;

        _region.printAbove(renderTaskLine(*item, _theme, _spin));
        foreach (line; detailLines.length > 1 ? detailLines[1 .. $] : null)
            _region.printAbove(followUpLine(*item, line));
        repaint();
    }

    private string followUpLine(in TaskItem item, string line) @safe pure
    {
        import std.array : appender;

        auto w = appender!string;
        foreach (_; 0 .. item.indent * 2 + 2)
            w.put(' ');
        w.put(_theme.paint(Semantic.muted, line));
        return w[];
    }

    private void repaint()
    {
        _region.update(renderTaskList(_items, _theme, _spin));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.core_cli.ui.theme : StatusGlyphs;

    // Colors off ⇒ plain-text lines the assertions can read directly.
    private enum Theme plain = Theme(colors: false, unicode: true);
}

@("tasklist.renderTaskLine.states")
@safe pure
unittest
{
    import core.time : msecs;

    assert(renderTaskLine(TaskItem(label: "clean tree"), plain) == "○ clean tree");
    assert(renderTaskLine(TaskItem(label: "ci --test", status: TaskStatus.running), plain, 2)
        == "⠹ ci --test");
    assert(renderTaskLine(
        TaskItem(label: "on main", status: TaskStatus.ok, elapsed: 1500.msecs), plain)
        == "✔ on main (1.5s)");
    assert(renderTaskLine(
        TaskItem(label: "push", status: TaskStatus.skipped, detail: "beyond --stage", indent: 1),
        plain)
        == "  ┄ push beyond --stage");
}

@("tasklist.renderTaskList.terminalRowsLeaveTheFrame")
@safe pure
unittest
{
    auto items = [
        TaskItem(label: "a", status: TaskStatus.ok),
        TaskItem(label: "b", status: TaskStatus.running),
        TaskItem(label: "c"),
    ];
    const lines = renderTaskList(items, plain);
    assert(lines.length == 2); // 'a' already graduated to the scrollback
    assert(lines[0] == "⠋ b");
    assert(lines[1] == "○ c");
}

@("tasklist.reporter.nonInteractiveTransitionLog")
@system
unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import sparkles.core_cli.ui.live : LiveRegion;

    string bytes;
    auto region = LiveRegion(
        (scope const(char)[] b) { bytes ~= b; }, () => ushort(0), false);
    auto tasks = TaskReporter(&region, plain);

    const a = tasks.add("working tree clean");
    const b = tasks.add("ci --test");
    tasks.start(a);
    tasks.succeed(a);
    tasks.start(b);
    tasks.fail(b, "tests failed\nlast line of output");
    region.finish();

    // Piped output: exactly the transition lines, no escapes, no frames.
    assert(!bytes.canFind('\x1b'));
    assert(bytes.startsWith("✔ working tree clean"));
    assert(bytes.canFind("✖ ci --test tests failed"));
    assert(bytes.canFind("\n  last line of output\n")); // follow-up detail line
}

@("tasklist.reporter.interactiveGraduation")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.core_cli.ui.live : LiveRegion;

    string bytes;
    auto region = LiveRegion(
        (scope const(char)[] b) { bytes ~= b; }, () => ushort(80), true);
    auto tasks = TaskReporter(&region, plain);

    const a = tasks.add("step");
    tasks.start(a);
    bytes = null;
    tasks.succeed(a);

    // The completed line graduates via printAbove and the frame empties.
    assert(bytes.canFind("✔ step"));
    region.finish();
    assert(tasks.items[a].status == TaskStatus.ok);
}
