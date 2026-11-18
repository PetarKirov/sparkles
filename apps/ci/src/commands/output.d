/// The plain rendering the commands share: headers, result boxes, resource
/// footers and run summaries.
module commands.output;

import commands.examples : exampleTimeout;
import commands.toolchain : withLdcDflags;
import core.time : Duration, MonoTime, msecs, seconds;
import sparkles.base.buffer : SharedBuffer;
import sparkles.base.hw_caps : hwLoadAverageCenti, hwLoadUnknown, hwOnlineCpuCount, hwParallelism;
import sparkles.base.logger : error, LogDelta, LogLevel, takeLogDelta, trace, writeLogDelta;
import sparkles.base.styled_template : styledText;
import sparkles.base.text.writers : writeDuration;
import sparkles.core_cli.process_utils :
    ChildStdin, executeMonitored, MonitoredResult, ResourceUsage, sampleThisProcessTree,
    selfAndChildrenCpuUsage, selfRssBytes;
import sparkles.core_cli.term_unstyle : unstyle;
import sparkles.ui.components.box : BoxProps, drawBox, drawBoxLines, TitleOverflow;
import std.algorithm : canFind, min;
import std.array : array, join;
import std.conv : text, to;
import std.process : execute;
import std.stdio : stdout, writeln;

/// Shared visible-column width for all UI chrome: `drawHeader` banners and the
/// `drawBox` `minWidth`/`maxWidth`. Keeping these in lockstep makes headers and
/// the boxes beneath them line up at a single, predictable width — capped at the
/// terminal so chrome never overflows a window narrower than 120 columns, and
/// defaulting to 120 when stdout is not a tty (piped output, CI).
package size_t uiWidth()
{
    import sparkles.base.term_caps : terminalSize;

    const w = terminalSize().width;
    return w == 0 ? 120 : min(120, w);
}

/// `BoxProps` for an example result box: a fixed `uiWidth` frame (long output
/// wraps in, short output pads out) so every box lines up under its banner. A
/// long title wraps into a nested title box rather than overflowing the frame,
/// matching the banner header above it.
package BoxProps resultBox(string footer)
{
    const w = uiWidth();
    return BoxProps(footer: footer, minWidth: w, maxWidth: w, titleOverflow: TitleOverflow.wrap);
}

struct FailureReplay
{
    string header;
    string[] outputLines;
    string footer;
}

/// GitHub Actions (and any other piped sink) fully-buffers stdout. A hang
/// after writing a header then produces an empty log — flush so the last
/// completed step is always visible.
package void flushStdout()
{
    stdout.flush();
}

/// GNU timeout owns a process group, so a wedged DUB child cannot survive the
/// launcher's timeout. The outer monitor gives its TERM/KILL sequence time to
/// finish. Strict comparison fixtures run on the documented Linux toolchain.
package MonitoredResult executeComparisonCommand(const(string)[] command, string label)
{
    auto budget = exampleTimeout();
    if (budget <= Duration.zero) budget = 300.seconds;
    auto result = executeLogged(["timeout", "--kill-after=2s", budget.total!"seconds".to!string ~ "s"]
        ~ command, label, budget + 5.seconds);
    if (result.status == 124 || result.status == 137)
        result.output ~= "\n[ci] comparison exceeded its process-group deadline\n";
    return result;
}

/**
Runs `args` like `std.process.execute`, returning a `MonitoredResult` (same
`status`/`output` fields the callers read). At `--log-level trace` it routes
through $(REF executeMonitored, sparkles,core_cli,process_utils), emitting the
process tree's resident-set size as it climbs plus a per-command summary — the
instrumentation for troubleshooting OOM during a build. At coarser levels it
samples on a lazy interval instead, which costs a `tryWait` poll and nothing
else.

Children always get `ChildStdin.empty`. Examples are batch work and must never
go interactive, but several probe `isatty(0)` to decide — and runners disagree
about it: a CircleCI `run` step allocates a TTY where a GitHub Actions step
does not. `README.md`'s `readme_prompts` example is the live case; inheriting a
terminal made it render a select prompt and then fail on the EOF that followed.
An empty stdin makes the answer `false` everywhere, including on a developer's
terminal.
*/
/// Fold the timeout into the captured output, so the reason travels with the
/// result to every renderer. A wedged child produces no output at all, so
/// without this its failure box is simply empty.
private MonitoredResult noteIfTimedOut(MonitoredResult result, Duration timeout)
{
    if (!result.timedOut)
        return result;

    SharedBuffer!(char, 32) budget;
    writeDuration(budget, timeout);
    result.output ~= i"\n[ci] no output — killed after $(budget[]) (timeout)\n".text;
    return result;
}

package MonitoredResult executeLogged(
    const(string)[] args, string label, Duration timeout = Duration.zero,
    const string[string] env = null)
{
    import std.array : join;
    import std.logger : globalLogLevel;
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.base.text.writers : writeBytes, writeDuration;

    const cmd = args.join(" ");
    const tracing = globalLogLevel <= LogLevel.trace;
    if (tracing)
        trace(i"{dim ▸ $(label):} {dim $(cmd)}");

    // Sample often enough that a compile's peak RSS is not a 5s-interval
    // miss — the figures feed the result-box footer, not just the trace.
    enum size_t logStep = 256UL << 20;   // 256 MiB
    size_t lastLogged;
    auto res = executeMonitored(args, 250.msecs, (in ResourceUsage u) @safe {
        if (!tracing || u.peakRssBytes < lastLogged + logStep)
            return;
        lastLogged = u.peakRssBytes;
        SharedBuffer!(char, 24) rss, cpu;
        writeBytes(rss, u.peakRssBytes);
        writeDuration(cpu, u.cpuTime);
        trace(i"{dim   $(label)} rss=$(rss[]) cpu=$(cpu[])");
    }, ChildStdin.empty, timeout, withLdcDflags(env));

    if (tracing)
    {
        auto stats = formatResourceStats(res.usage);
        if (res.usage.sampled)
        {
            SharedBuffer!(char, 24) ciRss;
            writeBytes(ciRss, selfRssBytes());
            trace(i"{dim ◂ $(label):} $(stats) exit=$(res.status) (ci_rss=$(ciRss[]))");
        }
        else
            trace(i"{dim ◂ $(label):} $(stats) exit=$(res.status)");
    }

    return noteIfTimedOut(res, timeout);
}

/**
Formats output lines for display, truncating if necessary.

`keepTail` decides *which* end survives, and it matters: a compiler or test
runner puts the diagnosis at the **end** of its output, so truncating a failure
to its first lines shows a header and a few passing cases while discarding the
error — the failure is reported without ever naming its cause. Failing boxes
therefore keep the tail; passing ones keep the head, where a build's summary
lives.
*/
package string[] formatOutputLines(string[] lines, size_t maxLines = 8,
    bool keepTail = false) @safe
in (maxLines > 1, "maxLines must be at least 2 for truncation indicator")
{
    if (lines.length == 0)
        return [styledText(i"{dim (no output)}")];

    if (lines.length > maxLines)
        return keepTail
            ? [styledText(i"{dim ...}")] ~ lines[$ - (maxLines - 1) .. $]
            : lines[0 .. maxLines - 1] ~ [styledText(i"{dim ...}")];

    return lines;
}

@("ci.formatOutputLines.failureKeepsTheTail")
@safe
unittest
{
    auto lines = ["a", "b", "c", "d", "e"];
    // Passing: the head (a build summary) survives.
    const head = formatOutputLines(lines, 3);
    assert(head[0] == "a" && head[1] == "b", "head-truncation keeps the first lines");
    // Failing: the tail (the error) survives — the whole point.
    const tail = formatOutputLines(lines, 3, keepTail: true);
    assert(tail[$ - 1] == "e" && tail[$ - 2] == "d", "tail-truncation keeps the last lines");
    // Short output is untouched either way.
    assert(formatOutputLines(lines, 99) == lines);
    assert(formatOutputLines(lines, 99, keepTail: true) == lines);
}

/// Compact resource fragment: `(usr 8.1s/sys 1.2s) | 842.2MiB`.
///
/// Optional leading wall (`12.4s `) when `includeWall` is true and known.
/// Empty when there is nothing to show.
private string formatResourceStats(in ResourceUsage u, bool includeWall = true) @safe
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.base.text.writers : writeBytes, writeDuration;

    if ((!includeWall || u.wallTime <= Duration.zero) && !u.sampled)
        return null;

    SharedBuffer!(char, 96) buf;
    if (includeWall && u.wallTime > Duration.zero)
        writeDuration(buf, u.wallTime);
    if (u.sampled)
    {
        if (buf.length)
            buf ~= ' ';
        buf ~= "(usr ";
        writeDuration(buf, u.userTime);
        buf ~= "/sys ";
        writeDuration(buf, u.systemTime);
        buf ~= ")";
        if (u.peakRssBytes)
        {
            buf ~= " | ";
            writeBytes(buf, u.peakRssBytes);
        }
    }
    return buf[].idup;
}

@("ci.formatResourceStats")
@safe
unittest
{
    import core.time : msecs;

    assert(formatResourceStats(ResourceUsage.init).length == 0);

    auto wallOnly = ResourceUsage(wallTime: 1500.msecs);
    const wall = formatResourceStats(wallOnly);
    assert(wall == "1.5s", wall);

    auto full = ResourceUsage(
        peakRssBytes: 842 * 1024 * 1024,
        wallTime: 12_400.msecs,
        userTime: 8100.msecs,
        systemTime: 1200.msecs,
        sampled: true,
    );
    const s = formatResourceStats(full);
    assert(s == "12.4s (usr 8.1s/sys 1.2s) | 842.0MiB", s);

    const noWall = formatResourceStats(full, includeWall: false);
    assert(noWall == "(usr 8.1s/sys 1.2s) | 842.0MiB", noWall);
}

/// Left-side result verdict: `✓ passed` / `✗ FAILED`.
package string resultVerdict(bool success) @safe
    => success
        ? styledText(i"{green ✓ passed}")
        : styledText(i"{red ✗ FAILED}");

/// Dim `Δt … | Δtᵢ …`, matching the log prefix columns.
private string formatLogDelta(in LogDelta delta) @safe
{
    SharedBuffer!(char, 48) stamp;
    writeLogDelta(stamp, delta);
    return styledText(i"{dim $(stamp[])}");
}

/// Right-side result footer: `Δt … | Δtᵢ … (usr …/sys …) | RSS`.
package string resultFooterRight(in ResourceUsage usage, in LogDelta delta) @safe
{
    SharedBuffer!(char, 96) buf;
    writeLogDelta(buf, delta);
    const stats = formatResourceStats(usage, includeWall: false);
    if (stats.length)
    {
        buf ~= ' ';
        buf ~= stats;
    }
    return styledText(i"{dim $(buf[])}");
}

@("ci.resultChrome.dualSided")
@safe
unittest
{
    const left = unstyle(resultVerdict(true));
    assert(left == "✓ passed", left);

    auto usage = ResourceUsage(
        peakRssBytes: 16UL << 20,
        userTime: 625.msecs,
        systemTime: 58.msecs,
        sampled: true,
    );
    const right = unstyle(resultFooterRight(usage, LogDelta(
        sinceStart: 33_600.msecs, sincePrev: 30_000.msecs)));
    assert(right.canFind("Δt "), right);
    assert(right.canFind("Δtᵢ "), right);
    assert(right.canFind("(usr "), right);
    assert(right.canFind("/sys "), right);
    assert(right.canFind(" | "), right);
    assert(right.canFind("MiB"), right);
}

/// Paint the box title immediately, then pull `lines` (the command) for the
/// body, then the footer. Fixed-width `resultBox` is what makes the title
/// emit before any content pull (`drawBoxLines` streaming path). Timing and
/// resource stats sit on the right of each border; the original title and
/// verdict stay on the left. `lines` is pulled lazily, so a
/// $(REF MonitoredLineRange, sparkles,core_cli,process_utils) streams every
/// child line in real time instead of truncating to a tail.
package void streamResultBox(Lines)(
    string header,
    auto ref Lines lines,
    scope string delegate() @safe makeFooter,
    scope string delegate(LogDelta) @safe makeFooterRight,
)
{
    const start = takeLogDelta();
    auto props = resultBox(null);
    props.titleRight = formatLogDelta(start);
    LogDelta end;
    props.footerNow = () {
        end = takeLogDelta();
        return makeFooter();
    };
    props.footerRightNow = () => makeFooterRight(end);
    foreach (line; drawBoxLines(lines, header, props))
    {
        writeln(line);
        stdout.flush();
    }
}

/// Displays the result box for an already-finished run (example replay).
package void displayResultBox(
    string[] outputLines, string header, bool success,
    ResourceUsage usage = ResourceUsage.init,
)
{
    const start = takeLogDelta();
    auto props = resultBox(resultVerdict(success));
    props.titleRight = formatLogDelta(start);
    props.footerRight = resultFooterRight(usage, takeLogDelta());
    outputLines
        // A failing box keeps the TAIL: a compiler/test-runner puts its
        // diagnosis last, so head-truncation reports the failure while hiding
        // its cause (this box once showed a header and four passing tests for
        // a failure whose error was three lines further down).
        .formatOutputLines(8, keepTail: !success)
        .drawBox(header, props)
        .writeln;
}

package void displayFailureReplay(FailureReplay replay)
{
    writeln();
    replay.outputLines
        .drawBox(replay.header, BoxProps(footer: replay.footer))
        .writeln;
}

/// Whole-run stats for a `ci test` / `ci test --special-modes all` Results box.
private struct TestRunStats
{
    ResourceUsage tree;       /// peak RSS / procs of the `ci` process group
    ResourceUsage cpu;        /// self+children rusage delta over the run
    Duration wall;
    uint workers;             /// `hwParallelism` — the worker cap
    uint onlineCpus;
    int peakLoadCenti;        /// peak 1-minute load, or `hwLoadUnknown`
    string[] failedPackages;
    size_t processed;
    size_t total;
}

/// Samples the `ci` process tree while packages run, so the Results box can
/// report peak RSS / procs of the whole group, not just the last child.
package struct RunMonitor
{
    ResourceUsage tree;
    ResourceUsage cpuBefore;
    MonoTime started;
    int peakLoadCenti = hwLoadUnknown;
    uint workers;
    uint onlineCpus;

    static RunMonitor start()
    {
        RunMonitor m;
        m.started = MonoTime.currTime;
        m.cpuBefore = selfAndChildrenCpuUsage();
        m.workers = hwParallelism();
        m.onlineCpus = hwOnlineCpuCount();
        m.sample();
        return m;
    }

    void sample() @safe
    {
        sampleThisProcessTree(tree);
        const load = hwLoadAverageCenti();
        if (load == hwLoadUnknown)
            return;
        if (peakLoadCenti == hwLoadUnknown || load > peakLoadCenti)
            peakLoadCenti = load;
    }

    TestRunStats finish(size_t processed, size_t total, string[] failedPackages)
    {
        sample();
        TestRunStats s;
        s.tree = tree;
        s.tree.wallTime = MonoTime.currTime - started;
        s.cpu = cpuUsageDelta(cpuBefore, selfAndChildrenCpuUsage());
        s.wall = s.tree.wallTime;
        s.workers = workers;
        s.onlineCpus = onlineCpus;
        s.peakLoadCenti = peakLoadCenti;
        s.failedPackages = failedPackages;
        s.processed = processed;
        s.total = total;
        return s;
    }
}

private ResourceUsage cpuUsageDelta(in ResourceUsage before, in ResourceUsage after)
    @safe pure nothrow @nogc
{
    ResourceUsage u;
    if (!before.sampled || !after.sampled)
        return u;
    u.userTime = after.userTime > before.userTime
        ? after.userTime - before.userTime : Duration.zero;
    u.systemTime = after.systemTime > before.systemTime
        ? after.systemTime - before.systemTime : Duration.zero;
    u.cpuTime = u.userTime + u.systemTime;
    u.sampled = true;
    return u;
}

/// Right-side Results title: `Δt … | workers=N online=M load=…`.
private string formatRunTitleRight(in TestRunStats s, in LogDelta delta) @safe
{
    import sparkles.base.text.writers : writeFixedPoint, writeInteger;

    SharedBuffer!(char, 96) buf;
    writeLogDelta(buf, delta);
    buf ~= " | workers=";
    writeInteger(buf, s.workers);
    buf ~= " online=";
    writeInteger(buf, s.onlineCpus);
    if (s.peakLoadCenti != hwLoadUnknown)
    {
        buf ~= " load=";
        writeFixedPoint(buf, s.peakLoadCenti, 2);
    }
    return styledText(i"{dim $(buf[])}");
}

/// Right-side Results footer: `(usr …/sys …) | RSS | N procs | R×`.
private string formatRunFooterRight(in TestRunStats s) @safe
{
    import sparkles.base.text.writers : writeBytes, writeDuration, writeFixedPoint,
        writeInteger;

    SharedBuffer!(char, 96) buf;
    const cpu = s.cpu.sampled ? s.cpu : s.tree;
    if (cpu.sampled)
    {
        buf ~= "(usr ";
        writeDuration(buf, cpu.userTime);
        buf ~= "/sys ";
        writeDuration(buf, cpu.systemTime);
        buf ~= ")";
    }
    if (s.tree.peakRssBytes)
    {
        if (buf.length)
            buf ~= " | ";
        writeBytes(buf, s.tree.peakRssBytes);
    }
    if (s.tree.peakProcs)
    {
        if (buf.length)
            buf ~= " | ";
        writeInteger(buf, s.tree.peakProcs);
        buf ~= " procs";
    }
    if (s.wall > Duration.zero && cpu.cpuTime > Duration.zero)
    {
        const wallH = s.wall.total!"hnsecs";
        const cpuH = cpu.cpuTime.total!"hnsecs";
        if (wallH > 0)
        {
            if (buf.length)
                buf ~= " | ";
            writeFixedPoint(buf, cast(ulong)(cpuH * 100 / wallH), 2);
            buf ~= "×";
        }
    }
    return buf.length ? styledText(i"{dim $(buf[])}") : null;
}

@("ci.formatRunChrome")
@safe
unittest
{
    auto stats = TestRunStats(
        tree: ResourceUsage(
            peakRssBytes: 16UL << 20,
            peakProcs: 14,
            sampled: true,
        ),
        cpu: ResourceUsage(
            userTime: 2500.msecs,
            systemTime: 500.msecs,
            cpuTime: 3000.msecs,
            sampled: true,
        ),
        wall: 1500.msecs,
        workers: 8,
        onlineCpus: 32,
        peakLoadCenti: 1497,
        processed: 35,
        total: 35,
    );
    const title = unstyle(formatRunTitleRight(stats, LogDelta(
        sinceStart: 1500.msecs, sincePrev: 100.msecs)));
    assert(title.canFind("workers=8"), title);
    assert(title.canFind("online=32"), title);
    assert(title.canFind("load=14.97"), title);

    const footer = unstyle(formatRunFooterRight(stats));
    assert(footer.canFind("(usr "), footer);
    assert(footer.canFind("/sys "), footer);
    assert(footer.canFind("MiB"), footer);
    assert(footer.canFind("14 procs"), footer);
    assert(footer.canFind("×"), footer);
}

/// The `ci test` Results box: pass/fail counts and failed names on the left,
/// whole-run resource stats on the right.
package void displayTestRunSummary(in TestRunStats stats)
{
    writeln();
    const failed = stats.failedPackages.length;
    const passed = stats.processed - failed;
    const success = failed == 0;
    const delta = takeLogDelta();

    auto props = resultBox(success
        ? styledText(i"{green ✓ $(passed) passed}")
        : styledText(i"{red ✗ $(failed) failed}"));
    props.titleRight = formatRunTitleRight(stats, delta);
    props.footerRight = formatRunFooterRight(stats);

    string[] body;
    if (success)
    {
        body ~= styledText(i"{green ✓} All packages passed!");
        body ~= styledText(i"{dim $(passed)/$(stats.processed) passed}");
    }
    else
    {
        body ~= styledText(i"{red ✗} $(failed) package(s) failed");
        body ~= styledText(i"{dim $(passed)/$(stats.processed) passed}");
        if (stats.failedPackages.length)
            body ~= styledText(i"{dim failed:} {red $(stats.failedPackages.join(", "))}");
        if (stats.processed < stats.total)
            body ~= styledText(
                i"{dim $(stats.total - stats.processed) not run (fail-fast)}");
    }
    writeln(body.drawBox(
        success ? styledText(i"{green Results}") : styledText(i"{red Results}"),
        props));
}

/// Displays the results summary.
package void displaySummary(size_t total, size_t failures)
{
    writeln();
    auto passed = total - failures;

    if (failures == 0)
    {
        writeln([
            styledText(i"{green ✓} All examples passed!"),
            styledText(i"{dim $(passed)/$(total) passed}"),
        ].drawBox(styledText(i"{green Results}")));
    }
    else
    {
        writeln([
            styledText(i"{red ✗} $(failures) example(s) failed"),
            styledText(i"{dim $(passed)/$(total) passed}"),
        ].drawBox(styledText(i"{red Results}")));
    }
}
