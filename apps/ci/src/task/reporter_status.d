/**
`ci test`'s transcript ([ci task-DAG CIC19](../../../../docs/specs/ci/task-dag/SPEC.md)):
what a run did, one status line per thing worth knowing, through `ci`'s
console (`console`), in the order it happened.

---
    Compiled base [library]  1.2s
    Compiled ui [test-root]  0.8s  layout.d changed
    Finished 2 packages in 2.6m  14 reused, 6 ran
---

A heading names the packages, `Linked` and `Tested` lines follow the
compiles, and a `Failed` line quotes the lines that explain the failure.

What a person acts on shows by default: what compiled, linked and was
tested, every failure with the lines that explain it, and the summary. What
explains the run but asks nothing of anyone is reported at trace, shown by
`--log-level trace`: each result reused from the store, why a task ran
(the file that changed), the steps too small to name (archives, generated
modules), the fallback variants a run did not need.

The child output a failure quotes is fenced from the CI service's command
parser, and the graph's redacted values are masked first, as the plain
transcript does (task-DAG TDO7).
*/
module task.reporter_status;

import core.time : Duration, MonoTime;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : appender, join, split;
import std.conv : text;
import std.sumtype : match;

import sparkles.base.logger : LogLevel, status;
import sparkles.base.status_line : detail, plain, StatusLine, StatusSpan, subject, tag, Tone, writeSpan,
    writeStatusLine, writeVerb;
import sparkles.base.text.writers : writeDuration;
import sparkles.build_primitives.task.graph : TaskGraph;
import sparkles.build_primitives.task.live_view : Transcript;
import sparkles.build_primitives.task.model;
import sparkles.ci_provider : CiLog;
import sparkles.base.text.width : Align;
import sparkles.ui.components.table : drawTableLines, TableBuilder, TableProps;

/// How the transcript lays its rows out: in columns either way.
enum TableStyle : ubyte
{
    clean, /// aligned columns, no rules and no header
    boxed, /// the columns framed, separated and headed
}

/// What the transcript says before the first task.
struct StatusOptions
{
    /// `Testing`, or `Building` for `--build-only`.
    string verb = "Testing";
    /// The selected packages, by name.
    string[] packages;
    /// The CI service's conventions: its fences and masks.
    CiLog ci;
    /// Lines a failure quotes at most: its last ones.
    size_t tailLines = 200;
    /// Whether rows are coloured, as the console's lines are.
    bool colour;
    /// The rows' frame.
    TableStyle table;
    /// The columns a boxed table may take; 0 for 100.
    size_t width;
}

/// The transcript, as a `Transcript` for the build graph's run.
final class StatusTranscript : Transcript
{
    /// Where its lines go: by default the console, through the logger.
    alias Emit = void delegate(LogLevel level, const(char)[] verb, Tone tone,
        scope const(StatusSpan)[] spans) @safe;

    ///
    this(const(TaskGraph)* graph, StatusOptions options, Emit emit = null) @safe
    {
        this.graph = graph;
        this.options = options;
        this.emit = emit !is null ? emit : (LogLevel level, const(char)[] verb, Tone tone,
            scope const(StatusSpan)[] spans) @safe {
            if (level == LogLevel.trace)
                status!(LogLevel.trace)(verb, tone, spans);
            else if (level == LogLevel.warning)
                status!(LogLevel.warning)(verb, tone, spans);
            else
                status(verb, tone, spans);
        };
        const n = graph.nodes.length;
        tails = new string[][n];
        why = new string[n];
        reused = new bool[n];
        parts = new Parts[n];
        foreach (i; 0 .. n)
            parts[i] = Parts.of((*graph)[TaskIndex(cast(uint) i)].id.text);
        widths = columnWidths(parts, options);
    }

    override void onEvent(const ref TaskEvent e) @safe
    {
        if (!started)
        {
            started = true;
            firstAt = e.at;
            header();
        }
        lastAt = e.at;
        e.payload.match!(
            (const TaskOutput o) { keep(o.task, e.text); },
            (const TaskStale s) { why[s.task.value] = staleWhy(s.reason, e.text); },
            (const TaskReused r) { reused[r.task.value] = true; },
            (const TaskNotice n) { noticed(n.task, e.text); },
            (const TaskFinished f) { finished(f.task, f.outcome, f.elapsed); },
            (const CancellationRequested c) { cancelled(c); },
            (const RunFinished r) { exitCode = r.exitCode; },
            (_) {},
        );
    }

    override void finish() @safe
    {
        if (done)
            return;
        done = true;
        if (started && boxed)
            line(LogLevel.info, bottomRule);
        if (blocked)
            say("Skipped", Tone.warning, subject(count(blocked, "task")),
                plain("whose prerequisites failed"));
        if (cancelledTasks)
            say("Cancelled", Tone.warning, subject(count(cancelledTasks, "task")));

        const wall = duration(lastAt - firstAt);
        auto work = appender!string;
        if (reusedTasks)
            work.put(text(reusedTasks, " reused"));
        if (ranTasks)
            work.put(text(work[].length ? ", " : "", ranTasks, " ran"));
        const packages = options.packages.length;
        if (failedPackages.length || exitCode != 0)
        {
            const failing = failedPackages.length ? failedPackages.join(", ") : "the run";
            say("Failed", Tone.failure, subject(failing),
                plain(text("(", failedPackages.length, " of ", packages, packages == 1 ? " package" : " packages",
                    ") in ", wall)), detail(work[]));
        }
        else
            say("Finished", Tone.success, subject(count(packages, "package")), plain("in " ~ wall),
                detail(work[]));
    }

private:
    Emit emit;
    const(TaskGraph)* graph;
    StatusOptions options;
    string[][] tails;
    string[] why;
    bool[] reused;
    Parts[] parts;
    size_t[columns] widths;
    string bottomRule;
    string[] failedPackages;
    size_t reusedTasks, ranTasks, blocked, cancelledTasks;
    int exitCode;
    bool started, done, masked;
    MonoTime firstAt, lastAt;

    bool boxed() const @safe => options.table == TableStyle.boxed;

    void say(const(char)[] verb, Tone tone, scope const(StatusSpan)[] spans...) @safe
        => emit(LogLevel.info, verb, tone, spans);

    // A line already laid out, bare.
    void line(LogLevel level, const(char)[] text) @safe
    {
        const StatusSpan[1] s = [plain(text)];
        emit(level, null, Tone.plain, s[]);
    }

    // One task's row, in the columns.
    void row(LogLevel level, const(char)[] verb, Tone tone, string pkg, string variant, string time,
        string handle, const(StatusSpan)[] note = null) @safe
    {
        TableBuilder b;
        b.row.cell!writeVerb(verb, tone, options.colour)
            .cell!writeSpan(subject(pkg), options.colour)
            .cell!writeSpan(tag(variant), options.colour)
            .cell!writeSpan(detail(handle), options.colour)
            .cell!writeNote(note, options.colour)
            .cell!writeSpan(detail(time), options.colour);
        rows(level, b);
    }

    // A line about no one task in the middle of the run: a status line, or
    // with the columns boxed, a row whose text spans them.
    void message(const(char)[] verb, Tone tone, scope const(StatusSpan)[] spans...) @safe
    {
        if (!boxed)
            return say(verb, tone, spans);
        TableBuilder b;
        b.row.cell!writeVerb(verb is null ? "" : verb, tone, options.colour)
            .cell!writeNote(spans.dup, options.colour).span(columns - 1);
        rows(LogLevel.info, b);
    }

    void rows(LogLevel level, ref TableBuilder b) @safe
    {
        import std.array : array;
        import std.string : stripRight;

        auto all = drawTableLines(b, props()).array;
        // A boxed row is the table's body between its rules; a clean one has
        // no frame, and the verb column's left gutter would set it a column
        // right of the status lines.
        foreach (l; boxed ? all[1 .. $ - 1] : all)
            line(level, boxed ? l : l.stripRight[l.length ? 1 : 0 .. $]);
    }

    TableProps props() const @safe
    {
        static immutable Align[columns] aligns = [Align.right, Align.left, Align.left, Align.left, Align.left,
            Align.right];
        return TableProps(border: boxed, columnSeparators: boxed, columnMinWidths: widths[].dup,
            columnMaxWidths: widths[].dup, columnAligns: aligns[]);
    }

    void header() @safe
    {
        string compiler;
        foreach (ref p; parts)
            if (p.compiler.length)
            {
                compiler = p.compiler == "ldc" ? "ldc2" : p.compiler;
                break;
            }
        const names = options.packages.length <= 6 ? options.packages.join(", ")
            : options.packages[0 .. 5].join(", ") ~ text(" and ", options.packages.length - 5, " more");
        say(options.verb, Tone.info, subject(names), plain(compiler.length ? "with " ~ compiler : ""));
        writeMasks();
        if (!boxed)
            return;
        // The top rule, the headings and the rule beneath them; the bottom
        // rule waits for the end.
        import std.array : array;

        TableBuilder b;
        b.row;
        foreach (h; headings)
            b.cell!writeSpan(subject(h), options.colour);
        b.row("", "", "", "", "", "");
        auto p = props();
        p.headerRows = 1;
        auto all = drawTableLines(b, p).array;
        foreach (l; all[0 .. $ - 2])
            line(LogLevel.info, l);
        bottomRule = all[$ - 1];
    }

    void keep(TaskIndex t, string line) @safe
    {
        foreach (l; line.split('\n'))
        {
            tails[t.value] ~= l;
            if (tails[t.value].length > options.tailLines * 2)
                tails[t.value] = tails[t.value][$ - options.tailLines .. $];
        }
    }

    // A line the task's driver reported of its own (TDM21): a warning row per
    // line, at once and whatever the task's outcome turns out to be, fenced
    // from the CI service's command parser as a failure's lines are.
    void noticed(TaskIndex t, string note) @safe
    {
        const p = parts[t.value];
        const label = (*graph)[t].label.length ? (*graph)[t].label : (*graph)[t].id.text;
        bare((ref w) => options.ci.beginUntrusted(w), LogLevel.warning);
        foreach (l; note.split('\n'))
        {
            auto w = appender!string;
            options.ci.writeUntrusted(w, l);
            row(LogLevel.warning, "Warning", Tone.warning, p.pkg.length ? p.pkg : label, p.variant, null, p.handle,
                [plain(w[])]);
        }
        bare((ref w) => options.ci.endUntrusted(w), LogLevel.warning);
    }

    void finished(TaskIndex t, const TaskOutcome outcome, Duration took) @safe
    {
        const p = parts[t.value];
        const label = (*graph)[t].label.length ? (*graph)[t].label : (*graph)[t].id.text;
        const name = p.pkg.length ? p.pkg : label;
        const time = rowTime(took);
        outcome.match!(
            (const Succeeded _) {
                if (reused[t.value])
                {
                    ++reusedTasks;
                    row(LogLevel.trace, "Reused", Tone.muted, name, p.variant, null, p.handle);
                    return;
                }
                ++ranTasks;
                succeeded(t, p, label, time);
            },
            (const Failed f) {
                ++ranTasks;
                failed(t, p, label, f, time);
            },
            (const Degraded d) {
                ++ranTasks;
                if (d.reason == DegradedReason.noCoverage)
                    row(LogLevel.info, "Warning", Tone.warning, name, p.variant, time, p.handle,
                        [plain("tested without coverage: it does not link under -cov")]);
                else
                    row(LogLevel.info, "Degraded", Tone.warning, name, p.variant, time, p.handle,
                        [detail(reasonText(d.reason))]);
            },
            (const Blocked b) {
                // The fallback a run did not need is no news.
                if (b.reason == BlockReason.conditionUnmet)
                    row(LogLevel.trace, "Unneeded", Tone.muted, name, p.variant, null, p.handle);
                else
                {
                    ++blocked;
                    row(LogLevel.trace, "Blocked", Tone.muted, name, p.variant, null, p.handle,
                        [detail(p.kind ~ ", by " ~ displayOf(b.root))]);
                }
            },
            (const Skipped s) {
                row(LogLevel.trace, "Skipped", Tone.muted, name, p.variant, null, p.handle,
                    [detail(reasonText(s.reason))]);
            },
            (const Cancelled _) { ++cancelledTasks; },
        );
    }

    void succeeded(TaskIndex t, const Parts p, string label, string time) @safe
    {
        const because = why[t.value];
        switch (p.kind)
        {
            case "compile":
                row(LogLevel.info, "Compiled", Tone.success, p.pkg, p.variant, time, p.handle, [detail(because)]);
                break;
            case "link":
                row(LogLevel.info, "Linked", Tone.success, p.pkg, p.variant, time, p.handle, [detail(because)]);
                break;
            case "test":
                row(LogLevel.info, "Tested", Tone.success, p.pkg, p.variant, time, p.handle,
                    [plain(testCounts(tails[t.value]))]);
                break;
            case "archive", "generate":
                row(LogLevel.trace, p.kind == "archive" ? "Archived" : "Generated", Tone.muted, p.pkg, p.variant,
                    time, p.handle);
                break;
            default:
                row(LogLevel.info, "Ran", Tone.success, label, null, time, null, [detail(because)]);
        }
    }

    void failed(TaskIndex t, const Parts p, string label, const Failed f, string time) @safe
    {
        if (p.pkg.length && !failedPackages.canFind(p.pkg))
            failedPackages ~= p.pkg;
        const counts = p.kind == "test" ? testCounts(tails[t.value]) : null;
        // A build failure names its kind: the row's verb says only that it failed.
        const note = counts.length ? counts : p.kind.length && p.kind != "test"
            ? p.kind ~ ": " ~ failureText(f) : failureText(f);
        row(LogLevel.info, "Failed", Tone.failure, p.pkg.length ? p.pkg : label, p.variant, time, p.handle,
            [plain(note)]);
        quote(t);
    }

    void cancelled(const CancellationRequested c) @safe
    {
        final switch (c.cause)
        {
            case CancelCause.failFast:
                message("Stopping", Tone.warning, plain("after the first failure (--fail-fast)"));
                break;
            case CancelCause.interrupt:
                message("Stopping", Tone.warning, plain("interrupted"));
                break;
            case CancelCause.terminate:
                message("Stopping", Tone.warning, plain("terminated"));
                break;
            case CancelCause.resources:
                message("Stopping", Tone.failure, plain("a file system the run writes is nearly full"));
                break;
        }
    }

    // A failure's lines, as its child wrote them (a test leg's passing tests
    // left out), fenced from the CI service: bare lines beneath the row that
    // reports it, or with the columns boxed, rows spanning them.
    void quote(TaskIndex t) @safe
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        // A test leg's passing tests explain nothing about its failures.
        auto lines = parts[t.value].kind == "test"
            ? tails[t.value].filter!(l => !l.startsWith("✓ ") && !l.startsWith("Summary: ")).array : tails[t.value];
        if (lines.length > options.tailLines)
        {
            message(null, Tone.plain, detail(text("… ", lines.length - options.tailLines, " earlier lines")));
            lines = lines[$ - options.tailLines .. $];
        }
        bare((ref w) => options.ci.beginUntrusted(w));
        foreach (l; lines)
        {
            auto w = appender!string;
            options.ci.writeUntrusted(w, l);
            message(null, Tone.plain, plain(w[]));
        }
        bare((ref w) => options.ci.endUntrusted(w));
    }

    // The whole lines `write` puts, each as a bare line: a CI service's
    // commands, which end in a line break.
    // At `level`, the level of the lines they fence, so that a filter that
    // lets those through keeps their fence.
    void bare(scope void delegate(ref typeof(appender!string())) @safe write, LogLevel level = LogLevel.info) @safe
    {
        import std.string : lineSplitter;

        auto w = appender!string;
        write(w);
        foreach (l; w[].lineSplitter)
            line(level, l);
    }

    // Every redacted environment value the graph's actions carry, masked on
    // the CI service before any line could show it.
    void writeMasks() @safe
    {
        import sparkles.build_primitives.task.action : ProcessAction;

        foreach (ref node; graph.nodes)
            node.action.match!(
                (const ref ProcessAction a) {
                    foreach (entry; a.envDelta)
                        if (entry.redacted)
                            bare((ref w) => options.ci.mask(w, entry.name, entry.value));
                },
                (_) {},
            );
    }

    string displayOf(TaskIndex t) @safe
    {
        const p = parts[t.value];
        return p.kind.length ? p.kind ~ " " ~ p.pkg : (*graph)[t].id.text;
    }
}

// The row's columns: verb, package, variant, task, note, time.
enum columns = 6;
static immutable string[columns] headings = ["", "Package", "Variant", "Task", "Note", "Time"];

/*
Each column as wide as the plan's widest entry in it, so that every row
lines up with the first: the verbs' column as wide as the status lines' (or
the longest verb, boxed), the time's as $(LREF rowTime)'s widest. The note
takes what the width leaves, so the time, right-aligned, ends each row at
the terminal's right edge, as the live view's durations do.
*/
size_t[columns] columnWidths(const Parts[] parts, const StatusOptions options) @safe
{
    import std.algorithm.comparison : max;
    import sparkles.base.status_line : displayWidth, verbColumns;

    const boxed = options.table == TableStyle.boxed;
    size_t[columns] w;
    w[0] = boxed ? "Generated".length : verbColumns;
    w[5] = "999.9ms".length;
    foreach (c; 1 .. columns)
        if (boxed)
            w[c] = max(w[c], headings[c].length);
    foreach (ref p; parts)
    {
        w[1] = max(w[1], displayWidth(p.pkg));
        w[2] = max(w[2], p.variant.length);
        w[3] = max(w[3], p.handle.length);
    }
    // A row is its columns and two gutters each; boxed, also the separators
    // and the borders; clean, without the gutters at either end. It stops a
    // column short of the edge, where a terminal would wrap.
    const others = w[0 .. 4].sum + w[5];
    const frame = boxed ? 2 * columns + columns + 1 : 2 * columns - 2;
    const width = (options.width ? options.width : 100) - 1;
    w[4] = width > others + frame + 16 ? width - others - frame : 16;
    return w;
}

size_t sum(const size_t[] xs) @safe pure nothrow @nogc
{
    size_t n;
    foreach (x; xs)
        n += x;
    return n;
}

// A row's note: its spans as a bare line, which spaces them.
void writeNote(W)(ref W w, const(StatusSpan)[] spans, bool colour)
{
    writeStatusLine(w, StatusLine(null, Tone.plain, spans), colour);
}

/// A build-graph task id's parts: `kind:package:role:compiler:key[:leg]`.
struct Parts
{
    string kind, pkg, role, compiler, key, leg;

    static Parts of(string id) @safe pure
    {
        const s = id.split(":");
        if (s.length < 5)
            return Parts.init;
        enum prefix = "sparkles.";
        return Parts(s[0], s[1].startsWith(prefix) ? s[1][prefix.length .. $] : s[1], s[2], s[3], s[4],
            s.length > 5 ? s[5] : null);
    }

    /// The task as a line's subject: its package, or its label.
    string name(string label) const @safe pure => pkg.length ? kind ~ " " ~ pkg : label;

    /// What the variant is: a test's leg, another task's role.
    string variant() const @safe pure => kind == "test" && leg.length ? leg : role;

    /**
    The task's short handle, `kind:key[:leg]` (`compile:b70e70`), which `ci
    cache explain` takes: the key cut to six digits. The key is the
    variant's, so the kind and the leg tell its tasks apart.
    */
    string handle() const @safe pure => kind.length
        ? kind ~ ":" ~ (key.length > 6 ? key[0 .. 6] : key) ~ (leg.length ? ":" ~ leg : "") : null;
}

/**
A test leg's counts, from the test runner's summary line (`Summary: 3 passed,
1 failed, 0 skipped`, `sparkles.test_runner.render.summaryLine`), the
nonzero ones, failures first; empty when no summary was written.
*/
string testCounts(const(string)[] lines) @safe pure
{
    import std.algorithm.iteration : filter;
    import std.string : strip;

    foreach_reverse (l; lines)
    {
        const at = l.strip;
        if (!at.startsWith("Summary: "))
            continue;
        string passed, failedN, skipped;
        foreach (part; at["Summary: ".length .. $].split(", "))
        {
            const w = part.split(" ");
            if (w.length != 2)
                continue;
            if (w[1] == "passed") passed = w[0];
            else if (w[1] == "failed") failedN = w[0];
            else if (w[1] == "skipped") skipped = w[0];
        }
        string[] out_;
        if (failedN.length && failedN != "0")
            out_ ~= failedN ~ " failed";
        out_ ~= passed ~ " passed";
        if (skipped.length && skipped != "0")
            out_ ~= skipped ~ " skipped";
        return out_.join(", ");
    }
    return null;
}

private:

string count(size_t n, string what) @safe pure => text(n, " ", what, n == 1 ? "" : "s");

/// A row's time: one decimal always, in ms below a second, then s, m, h —
/// `423.0ms`, `8.9s`, `2.6m` — so the column's digits line up.
public string rowTime(Duration d) @safe
{
    import core.time : minutes, msecs, seconds, usecs;

    auto w = appender!string;
    // A unit is kept while the value rounds below its next one.
    if (d < 999_950.usecs)
        writeDuration!"msecs"(w, d, 1);
    else if (d < 59_950.msecs)
        writeDuration!"seconds"(w, d, 1);
    else if (d < 59.minutes + 57.seconds)
        writeDuration!"minutes"(w, d, 1);
    else
        writeDuration!"hours"(w, d, 1);
    return w[];
}

/// The units step up where a value would round to the next one.
@("task.reporter_status.rowTime.oneDecimal")
@safe unittest
{
    import core.time : msecs, minutes, seconds, usecs;

    assert(rowTime(2.msecs) == "2.0ms");
    assert(rowTime(423.msecs) == "423.0ms");
    assert(rowTime(999_960.usecs) == "1.0s");
    assert(rowTime(8_940.msecs) == "8.9s");
    assert(rowTime(156.seconds) == "2.6m");
    assert(rowTime(90.minutes) == "1.5h");
}

string duration(Duration d) @safe
{
    auto w = appender!string;
    writeDuration(w, d);
    return w[];
}

string staleWhy(StaleReason r, string path) @safe pure
{
    import std.path : baseName;

    final switch (r)
    {
        case StaleReason.inputChanged: return path.length ? path.baseName ~ " changed" : "an input changed";
        case StaleReason.absentAppeared: return path.length ? path.baseName ~ " appeared" : "a file appeared";
        case StaleReason.prerequisiteRan: return null;
        case StaleReason.corrupt: return "its stored result was corrupt";
        case StaleReason.evicted: return "its stored result was evicted";
        case StaleReason.conservative: return null;
        case StaleReason.noEntry: return null;
        case StaleReason.noRecord: return null;
    }
}

string failureText(const Failed f) @safe
{
    import sparkles.base.text.wire_names : AnyFormat;
    import sparkles.base.text.writers : writeEnumMemberName;

    auto w = appender!string;
    switch (f.reason)
    {
        case FailureReason.exitStatus: w.put(text("exit status ", f.status)); break;
        case FailureReason.signal: w.put(f.status ? text("signal ", f.status) : "interrupted"); break;
        default: writeEnumMemberName!AnyFormat(w, f.reason);
    }
    return w[];
}

string reasonText(E)(E reason) @safe
{
    import sparkles.base.text.wire_names : AnyFormat;
    import sparkles.base.text.writers : writeEnumMemberName;

    auto w = appender!string;
    writeEnumMemberName!AnyFormat(w, reason);
    return w[];
}

/// The counts come from the test runner's own summary line, failures first.
@("task.reporter_status.testCounts.fromTheSummaryLine")
@safe unittest
{
    import sparkles.test_runner.render : summaryLine;

    assert(testCounts(["✓ a", summaryLine(1078, 0, 4)]) == "1078 passed, 4 skipped");
    assert(testCounts([summaryLine(311, 2, 0), "trailing"]) == "2 failed, 311 passed");
    assert(testCounts(["no summary"]) is null);
}

/// A task id's parts name its package without the repository's prefix.
@("task.reporter_status.Parts.ofATaskId")
@safe pure unittest
{
    const p = Parts.of("test:sparkles.base:test-root:ldc:4da63ee800ca:serial");
    assert(p.kind == "test" && p.pkg == "base" && p.role == "test-root" && p.leg == "serial");
    assert(p.variant == "serial" && p.handle == "test:4da63e:serial");
    assert(Parts.of("compile:sparkles.wired:library:ldc:b70e707f743f").handle == "compile:b70e70");
    assert(Parts.of("check-sidebar").kind is null);
}

/**
What the live view and a failure call task `t`: its kind, its package, and
its role, or for a test its leg when it is the serial one — `compile base
[library]`, `test base` — the words a status line uses. A task whose id is
not a build-graph action's is its label, or its id.
*/
public string taskName(const ref TaskGraph graph, TaskIndex t) @safe pure
{
    const p = Parts.of(graph[t].id.text);
    if (!p.kind.length)
        return graph[t].label.length ? graph[t].label : graph[t].id.text;
    if (p.kind == "test")
        return p.leg == "serial" ? "test " ~ p.pkg ~ " [serial]" : "test " ~ p.pkg;
    return p.kind ~ " " ~ p.pkg ~ (p.role.length ? " [" ~ p.role ~ "]" : "");
}

/// A scripted run reads as its rows: what ran, a failure with the lines that
/// explain it, the summary; the reused results and the fallback a run did
/// not need only at trace (CIC19). Every row's columns line up, sized from
/// the plan.
@("task.reporter_status.StatusTranscript.aRunAsStatusLines")
@system unittest
{
    const run = scriptedRun(TableStyle.clean);
    assert(run.info[0 .. 5] == [
        "     Testing base, ui with ldc2",
        "    Compiled  ui    test-root  compile:5b1166        layout.d changed                         2.0ms",
        "      Tested  base  parallel   test:6c2277:parallel  1078 passed, 4 skipped                   3.0ms",
        "      Failed  ui    parallel   test:7d3388:parallel  1 failed, 311 passed                     4.0ms",
        "✗ ui.broken",
    ], run.info.join("\n"));
    assert(run.info[5] == "    AssertError: no", "only what explains the failure");
    assert(run.info[$ - 1].startsWith("      Failed ui (1 of 2 packages) in "), run.info[$ - 1]);
    assert(run.info[$ - 1].endsWith("1 reused, 3 ran"), run.info[$ - 1]);
    assert(run.trace == [
        "      Reused  base  library    compile:4a0065",
        "    Unneeded  ui    test-root  link:8e4499",
    ], run.trace.join("\n"));
}

/// TDM21: a notice of a task that succeeds quietly, reused here, is a
/// warning row all the same.
@("task.reporter_status.StatusTranscript.noticeOfAQuietTask")
@system unittest
{
    const run = scriptedRun(TableStyle.clean, 0, ["replacing 4a0065 waits for a lease", "two\nlines"]);
    assert(run.warning == [
        "     Warning  base  library    compile:4a0065        replacing 4a0065 waits for a lease",
        "     Warning  base  library    compile:4a0065        two",
        "     Warning  base  library    compile:4a0065        lines",
    ], run.warning.join("\n"));
    assert(run.trace[0] == "      Reused  base  library    compile:4a0065", run.trace.join("\n"));

    // On a CI service, each notice is fenced from its command parser at the
    // notice's own level, which a filter that keeps the rows keeps too.
    import sparkles.ci_provider : CiProvider;

    CiLog github;
    github.provider = CiProvider.githubActions;
    github.stopToken = "feedfacefeedfacefeedfacefeedface";
    const ci = scriptedRun(TableStyle.clean, 0, ["::error::planted"], github);
    assert(ci.warning == [
        "::stop-commands::feedfacefeedfacefeedfacefeedface",
        "     Warning  base  library    compile:4a0065        ::error::planted",
        "::feedfacefeedfacefeedfacefeedface::",
    ], ci.warning.join("\n"));
}

/// Boxed, the same rows are framed and headed, and a failure's lines span
/// the columns beneath its row.
@("task.reporter_status.StatusTranscript.boxed")
@system unittest
{
    import sparkles.base.text.grapheme : visibleWidth;

    const run = scriptedRun(TableStyle.boxed, 96);
    assert(run.info[0 .. $ - 1] == [
        "     Testing base, ui with ldc2",
        "╭───────────┬─────────┬───────────┬──────────────────────┬──────────────────────────┬─────────╮",
        "│           │ Package │ Variant   │ Task                 │ Note                     │    Time │",
        "┝━━━━━━━━━━━┿━━━━━━━━━┿━━━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━━━━━━┿━━━━━━━━━┥",
        "│  Compiled │ ui      │ test-root │ compile:5b1166       │ layout.d changed         │   2.0ms │",
        "│    Tested │ base    │ parallel  │ test:6c2277:parallel │ 1078 passed, 4 skipped   │   3.0ms │",
        "│    Failed │ ui      │ parallel  │ test:7d3388:parallel │ 1 failed, 311 passed     │   4.0ms │",
        "│           │ ✗ ui.broken                                                                     │",
        "│           │     AssertError: no                                                             │",
        "╰───────────┴─────────┴───────────┴──────────────────────┴──────────────────────────┴─────────╯",
    ], run.info.join("\n"));
    assert(run.info[$ - 1].startsWith("      Failed ui (1 of 2 packages) in "), run.info[$ - 1]);
    foreach (l; run.info[1 .. $ - 1])
        assert(visibleWidth(l) == 95, l);
}

version (unittest)
{
    struct ScriptedLines
    {
        string[] info, trace, warning;
    }

    // `aRunAsStatusLines`'s run, as the lines the transcript writes.
    ScriptedLines scriptedRun(TableStyle table, size_t width = 0, string[] libNotices = null, CiLog ci = CiLog.init)
    {
        import core.time : msecs;
        import sparkles.base.status_line : StatusLine, writeStatusLine;
        import sparkles.build_primitives.task.action : InertAction, TaskAction;
        import sparkles.build_primitives.task.executor : ExecutorOptions;
        import sparkles.build_primitives.task.testing : graphOf, runFake, Script;
        import sparkles.test_runner.render : summaryLine;

        enum lib = "compile:sparkles.base:library:ldc:4a0065aaaaaa";
        enum cov = "compile:sparkles.ui:test-root:ldc:5b1166bbbbbb";
        enum test = "test:sparkles.base:test-root:ldc:6c2277cccccc:parallel";
        enum broken = "test:sparkles.ui:test-root:ldc:7d3388dddddd:parallel";
        enum fallback = "link:sparkles.ui:test-root:ldc:8e4499eeeeee";
        static TaskNode node(string id)
        {
            const parts = id.split(":");
            return TaskNode(taskId(parts).value, TaskKind.build, null, PresentationKey(0, id), ResourceClaim(1),
                TaskAction(InertAction(id)));
        }

        auto g = new TaskGraph;
        *g = graphOf([node(lib), node(cov), node(test), node(broken), node(fallback)], null);
        auto run = runFake(*g, [
            lib: Script(1.msecs, reused: true, notices: libNotices),
            cov: Script(2.msecs, freshness: Freshness(Freshness.Kind.stale, reason: StaleReason.inputChanged,
                path: "libs/ui/src/sparkles/ui/layout.d")),
            test: Script(3.msecs, lines: ["✓ base.one", summaryLine(1078, 0, 4)]),
            broken: Script(4.msecs, TaskOutcome(Failed(FailureReason.exitStatus, 1)),
                ["✓ ui.fine", "✗ ui.broken", "    AssertError: no", summaryLine(311, 1, 0)]),
            fallback: Script(5.msecs, TaskOutcome(Blocked(BlockReason.conditionUnmet))),
        ], ExecutorOptions(capacity: 1));

        ScriptedLines lines;
        auto transcript = new StatusTranscript(g, StatusOptions(packages: ["base", "ui"], table: table,
            width: width, ci: ci), (LogLevel level, const(char)[] verb, Tone tone, scope const(StatusSpan)[] spans) @safe {
                auto w = appender!string;
                writeStatusLine(w, StatusLine(verb, tone, spans), false);
                (level == LogLevel.trace ? lines.trace : level == LogLevel.warning ? lines.warning : lines.info) ~= w[];
            });
        foreach (ref e; run.events)
            transcript.onEvent(e);
        transcript.finish();
        return lines;
    }
}
