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
import sparkles.base.status_line : detail, plain, StatusSpan, subject, tag, Tone;
import sparkles.base.text.writers : writeDuration;
import sparkles.build_primitives.task.graph : TaskGraph;
import sparkles.build_primitives.task.live_view : Transcript;
import sparkles.build_primitives.task.model;
import sparkles.ci_provider : CiLog;

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
        foreach (ref p; parts)
        {
            if (p.kind == "test" && p.leg.length && !legsOf.get(p.pkg, null).canFind(p.leg))
                legsOf[p.pkg] ~= p.leg;
            variantsOf[p.kind ~ " " ~ p.pkg ~ " " ~ p.role] ~= p.key;
        }
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
    string[][string] legsOf;
    string[][string] variantsOf;
    string[] failedPackages;
    size_t reusedTasks, ranTasks, blocked, cancelledTasks;
    int exitCode;
    bool started, done, masked;
    MonoTime firstAt, lastAt;

    void say(const(char)[] verb, Tone tone, scope const(StatusSpan)[] spans...) @safe
        => emit(LogLevel.info, verb, tone, spans);

    void note(const(char)[] verb, Tone tone, scope const(StatusSpan)[] spans...) @safe
        => emit(LogLevel.trace, verb, tone, spans);

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

    void finished(TaskIndex t, const TaskOutcome outcome, Duration took) @safe
    {
        const p = parts[t.value];
        const label = (*graph)[t].label.length ? (*graph)[t].label : (*graph)[t].id.text;
        const time = duration(took);
        outcome.match!(
            (const Succeeded _) {
                if (reused[t.value])
                {
                    ++reusedTasks;
                    note("Reused", Tone.muted, subject(p.name(label)), tag(roleTag(p)));
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
                    say("Warning", Tone.warning, subject(p.pkg), plain("tested without coverage:"),
                        plain("it does not link under -cov"));
                else
                    say("Degraded", Tone.warning, subject(p.name(label)), tag(roleTag(p)),
                        detail(reasonText(d.reason)));
            },
            (const Blocked b) {
                // The fallback a run did not need is no news.
                if (b.reason == BlockReason.conditionUnmet)
                    note("Unneeded", Tone.muted, subject(p.name(label)), tag(roleTag(p)));
                else
                {
                    ++blocked;
                    note("Blocked", Tone.muted, subject(p.name(label)), tag(roleTag(p)),
                        detail("by " ~ displayOf(b.root)));
                }
            },
            (const Skipped s) {
                note("Skipped", Tone.muted, subject(p.name(label)), detail(reasonText(s.reason)));
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
                say("Compiled", Tone.success, subject(p.pkg), tag(roleTag(p)), detail(time), detail(because));
                break;
            case "link":
                say("Linked", Tone.success, subject(p.pkg), tag(roleTag(p)), detail(time), detail(because));
                break;
            case "test":
                const counts = testCounts(tails[t.value]);
                say("Tested", Tone.success, subject(p.pkg), tag(legTag(p)), plain(counts.length ? counts : ""),
                    detail(time));
                break;
            case "archive", "generate":
                note(p.kind == "archive" ? "Archived" : "Generated", Tone.muted,
                    subject(p.pkg), tag(roleTag(p)), detail(time));
                break;
            default:
                say("Ran", Tone.success, subject(label), detail(time), detail(because));
        }
    }

    void failed(TaskIndex t, const Parts p, string label, const Failed f, string time) @safe
    {
        if (p.pkg.length && !failedPackages.canFind(p.pkg))
            failedPackages ~= p.pkg;
        if (p.kind == "test")
        {
            const counts = testCounts(tails[t.value]);
            say("Failed", Tone.failure, subject(p.pkg), tag(legTag(p)),
                plain(counts.length ? counts : failureText(f)), detail(time));
        }
        else
            say("Failed", Tone.failure, subject(p.kind.length ? p.kind ~ " " ~ p.pkg : label), tag(roleTag(p)),
                plain(failureText(f)), detail(time));
        quote(t);
    }

    void cancelled(const CancellationRequested c) @safe
    {
        final switch (c.cause)
        {
            case CancelCause.failFast:
                say("Stopping", Tone.warning, plain("after the first failure (--fail-fast)"));
                break;
            case CancelCause.interrupt:
                say("Stopping", Tone.warning, plain("interrupted"));
                break;
            case CancelCause.terminate:
                say("Stopping", Tone.warning, plain("terminated"));
                break;
        }
    }

    // A failure's lines, as its child wrote them (a test leg's passing tests
    // left out), fenced from the CI
    // service: bare lines, beneath the line that reports it.
    void quote(TaskIndex t) @safe
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        // A test leg's passing tests explain nothing about its failures.
        auto lines = parts[t.value].kind == "test"
            ? tails[t.value].filter!(l => !l.startsWith("✓ ") && !l.startsWith("Summary: ")).array : tails[t.value];
        if (lines.length > options.tailLines)
        {
            say(null, Tone.plain, detail(text("… ", lines.length - options.tailLines, " earlier lines")));
            lines = lines[$ - options.tailLines .. $];
        }
        bare((ref w) => options.ci.beginUntrusted(w));
        foreach (l; lines)
        {
            auto w = appender!string;
            options.ci.writeUntrusted(w, l);
            say(null, Tone.plain, plain(w[]));
        }
        bare((ref w) => options.ci.endUntrusted(w));
    }

    // The whole lines `write` puts, each as a bare line: a CI service's
    // commands, which end in a line break.
    void bare(scope void delegate(ref typeof(appender!string())) @safe write) @safe
    {
        import std.string : lineSplitter;

        auto w = appender!string;
        write(w);
        foreach (l; w[].lineSplitter)
            say(null, Tone.plain, plain(l));
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

    string legTag(const Parts p) @safe => legsOf.get(p.pkg, null).length > 1 ? "[" ~ p.leg ~ "]" : null;

    // `[role]`, and the variant's key when the role has more than one: two
    // builds of one library, say, with and without `-cov`.
    string roleTag(const Parts p) @safe
    {
        if (!p.role.length)
            return null;
        const variants = variantsOf.get(p.kind ~ " " ~ p.pkg ~ " " ~ p.role, null);
        return variants.length > 1 && p.key.length >= 6 ? "[" ~ p.role ~ " " ~ p.key[0 .. 6] ~ "]"
            : "[" ~ p.role ~ "]";
    }

    string displayOf(TaskIndex t) @safe
    {
        const p = parts[t.value];
        return p.kind.length ? p.kind ~ " " ~ p.pkg : (*graph)[t].id.text;
    }
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

    /// `[role]`, or nothing.
    string roleTag() const @safe pure => role.length ? "[" ~ role ~ "]" : null;
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

/// A scripted run reads as its status lines: what ran, a failure with the
/// lines that explain it, the summary; the reused results and the fallback a
/// run did not need only at trace (CIC19).
@("task.reporter_status.StatusTranscript.aRunAsStatusLines")
@system unittest
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

    auto g = graphOf([node(lib), node(cov), node(test), node(broken), node(fallback)], null);
    auto run = runFake(g, [
        lib: Script(1.msecs, reused: true),
        cov: Script(2.msecs, freshness: Freshness(Freshness.Kind.stale, reason: StaleReason.inputChanged,
            path: "libs/ui/src/sparkles/ui/layout.d")),
        test: Script(3.msecs, lines: ["✓ base.one", summaryLine(1078, 0, 4)]),
        broken: Script(4.msecs, TaskOutcome(Failed(FailureReason.exitStatus, 1)),
            ["✓ ui.fine", "✗ ui.broken", "    AssertError: no", summaryLine(311, 1, 0)]),
        fallback: Script(5.msecs, TaskOutcome(Blocked(BlockReason.conditionUnmet))),
    ], ExecutorOptions(capacity: 1));

    string[] info, trace;
    auto transcript = new StatusTranscript(&g, StatusOptions(packages: ["base", "ui"]),
        (LogLevel level, const(char)[] verb, Tone tone, scope const(StatusSpan)[] spans) @safe {
            auto w = appender!string;
            writeStatusLine(w, StatusLine(verb, tone, spans), false);
            (level == LogLevel.trace ? trace : info) ~= w[];
        });
    foreach (ref e; run.events)
        transcript.onEvent(e);
    transcript.finish();

    assert(info[0] == "     Testing base, ui with ldc2", info[0]);
    assert(info[1] == "    Compiled ui [test-root]  2.0ms  layout.d changed", info[1]);
    assert(info[2] == "      Tested base 1078 passed, 4 skipped  3.0ms", info[2]);
    assert(info[3] == "      Failed ui 1 failed, 311 passed  4.0ms", info[3]);
    assert(info[4 .. 6] == ["✗ ui.broken", "    AssertError: no"], "only what explains the failure");
    assert(info[$ - 1].startsWith("      Failed ui (1 of 2 packages) in "), info[$ - 1]);
    assert(info[$ - 1].endsWith("1 reused, 3 ran"), info[$ - 1]);
    assert(trace == ["      Reused compile base [library]", "    Unneeded link ui [test-root]"]);
}
