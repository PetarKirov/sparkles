/**
 * Rendering of test results, benchmark tables, and run summaries.
 *
 * All functions are pure string producers parameterized by `colored`, so the
 * exact output is unit-testable; the runner streams them to `stdout`.
 */
module sparkles.test_runner.reporting;

import core.interpolation : InterpolationFooter, InterpolationHeader;
import core.time : Duration;

import sparkles.base.text.grapheme : byGraphemeCluster, visibleWidth;

import sparkles.test_runner.bench : BenchStats;
import sparkles.test_runner.ctfe_trace : CtfeTestCost;
import sparkles.test_runner.model : Test, TestLocation, TestResult, Thrown;

/// Whether `sparkles:core-cli` is in the tested package's dependency closure.
/// It cannot be a dub dependency of this package (that would be a cycle when
/// testing `base`/`core-cli` themselves), so its UI niceties are detected by
/// introspection and skipped when absent.
private enum bool hasCoreCliUi = __traits(compiles, {
    import sparkles.core_cli.ui.osc_link : oscLink;
    import sparkles.core_cli.ui.table : drawTable;
});

/// Likewise for `core-cli`'s terminal-size query, used to width-truncate result
/// lines. Absent in `base`'s own test build (no `core-cli` there), where it
/// degrades to `0` = unknown = no truncation.
private enum bool hasCoreCliTermSize = __traits(compiles, {
    import sparkles.core_cli.term_caps : terminalWidth;
});

/// Terminal width in cells via `core-cli` when available, else `0` (unknown →
/// callers skip truncation). `0` is also the value on a non-tty (piped output),
/// so redirected runs stay byte-identical to the untruncated form.
package uint detectTerminalWidth()
{
    static if (hasCoreCliTermSize)
    {
        import sparkles.core_cli.term_caps : terminalWidth;

        return terminalWidth();
    }
    else
        return 0;
}

/// Renders a styled IES with ANSI escapes when `colored`, plain text otherwise.
package string render(Args...)(
    bool colored,
    InterpolationHeader header,
    Args args,
    InterpolationFooter footer,
)
{
    import sparkles.base.styled_template : plainText, styledText;

    return colored
        ? styledText(header, args, footer)
        : plainText(header, args, footer);
}

/// A duration rendered with `sparkles.base.text.writers` (`1.5µs`, `12.3ms`, …).
string formatDuration(Duration duration) @safe
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.writers : writeDuration;

    SmallBuffer!(char, 32) buf;
    buf.writeDuration(duration);
    return buf[].idup;
}

@("formatDuration.units")
@safe
unittest
{
    import core.time : msecs, usecs;

    assert(formatDuration(1500.usecs) == "1.5ms");
    assert(formatDuration(12.msecs) == "12.0ms");
}

/// A `file:line` reference; an OSC 8 hyperlink (`file://` URI) when `colored`.
string formatLocation(in TestLocation location, bool colored) @safe
{
    import std.conv : text;

    if (!location.file.length)
        return null;

    const label = text(location.file, ':', location.line);
    static if (hasCoreCliUi)
    {
        if (colored)
        {
            import std.path : absolutePath;
            import sparkles.core_cli.ui.osc_link : oscLink;

            const uri = text("file://", location.file.absolutePath, "#L", location.line);
            return "[" ~ oscLink(label, uri) ~ "]";
        }
    }
    return "[" ~ label ~ "]";
}

@("formatLocation.plain")
@safe
unittest
{
    assert(formatLocation(TestLocation(file: "src/foo.d", line: 42, column: 1), false) == "[src/foo.d:42]");
    assert(formatLocation(TestLocation.init, false) is null);
}

/// The tail of a dotted `moduleName` fitting in `budget` terminal cells
/// *including* a leading `…`, snapped to start at a `.` segment boundary when
/// possible. Widths are cells (via `visibleWidth`) and the cut lands on a
/// grapheme boundary, so a wide glyph is never split. Returns `moduleName`
/// unchanged when `budget` is too small to keep a useful tail.
private string truncateModulePath(string moduleName, size_t budget) @safe
{
    import std.string : indexOf;

    if (budget < 2)
        return moduleName;
    const cap = budget - 1; // reserve one cell for the ellipsis

    // Byte offset and cell width of each grapheme cluster.
    size_t[] offsets;
    size_t[] widths;
    size_t offset = 0, total = 0;
    foreach (cluster; moduleName.byGraphemeCluster)
    {
        offsets ~= offset;
        widths ~= cluster.width;
        offset += cluster.slice.length;
        total += cluster.width;
    }

    if (total <= cap)
        return moduleName; // already fits (callers only truncate on overflow)

    // Drop leading clusters until the suffix fits `cap` cells.
    size_t startIdx = 0, remaining = total;
    while (startIdx < offsets.length && remaining > cap)
    {
        remaining -= widths[startIdx];
        startIdx++;
    }
    if (startIdx >= offsets.length)
        return moduleName; // nothing fits; don't emit a lone "…"

    size_t start = offsets[startIdx];
    // Snap forward past the first '.' at or after `start` so the tail shows
    // whole trailing segments (`…text.grapheme`, not `…xt.grapheme`).
    const dot = moduleName[start .. $].indexOf('.');
    if (dot >= 0 && start + dot + 1 < moduleName.length)
        start += dot + 1;
    return "…" ~ moduleName[start .. $];
}

/// Renders a result line via `build(moduleName)`, shortening the module path to
/// fit `width` cells when the full line overflows. `width == 0` (unknown /
/// non-tty) disables truncation. Only the plain module string is shortened —
/// before it is styled — so ANSI escapes stay intact.
private string fitWidth(scope string delegate(string) @safe build,
    string moduleName, uint width) @safe
{
    auto line = build(moduleName);
    if (width == 0)
        return line;
    const lineWidth = visibleWidth(line);
    if (lineWidth <= width)
        return line;
    const overhead = lineWidth - visibleWidth(moduleName); // non-module cells
    if (width <= overhead + 1) // no room for "…" plus at least one cell
        return line;
    return build(truncateModulePath(moduleName, width - overhead));
}

/// The per-test result line: ` ✓ module name` / ` ✗ module name`, plus
/// duration and location when `verbose`. `width` (cells; `0` = unknown)
/// truncates the module path on the compact, non-verbose line when it would
/// overflow the terminal.
string formatResultLine(in TestResult result, bool colored, bool verbose, uint width = 0) @safe
{
    const test = result.test;
    const name = test.name;
    const succeeded = result.succeeded;

    string build(string moduleName) @safe
    {
        return succeeded
            ? render(colored, i" {green ✓} {dim $(moduleName)} $(name)")
            : render(colored, i" {bold.red ✗} {dim $(moduleName)} {bold $(name)}");
    }

    // Truncation applies only to the compact (non-verbose) line. `.idup` drops
    // the conservative `return scope` on `moduleName` (it is GC-backed already).
    auto line = verbose ? build(test.moduleName) : fitWidth(&build, test.moduleName.idup, width);

    if (verbose)
    {
        const duration = formatDuration(result.duration);
        line ~= render(colored, i" {dim ($(duration))}");
        if (const location = formatLocation(test.location, colored))
            line ~= render(colored, i" {dim $(location)}");
    }

    return line;
}

@("formatResultLine.plain")
@safe
unittest
{
    import core.time : usecs;

    auto result = TestResult(
        test: Test(fullName: "pkg.mod.__unittest_L1_C1", name: "case"),
        succeeded: true,
        duration: 1500.usecs,
    );
    assert(formatResultLine(result, false, false) == " ✓ pkg.mod case");

    result.test.location = TestLocation(file: "src/mod.d", line: 7, column: 1);
    assert(formatResultLine(result, false, true) == " ✓ pkg.mod case (1.5ms) [src/mod.d:7]");

    result.succeeded = false;
    assert(formatResultLine(result, false, false) == " ✗ pkg.mod case");
}

@("formatResultLine.truncation")
@safe
unittest
{
    const result = TestResult(
        test: Test(fullName: "sparkles.base.text.grapheme.__unittest_L1_C1", name: "case"),
        succeeded: true,
    );
    // Wide terminal and unknown width (0): full module path, no truncation.
    assert(formatResultLine(result, false, false, 80) == " ✓ sparkles.base.text.grapheme case");
    assert(formatResultLine(result, false, false, 0) == " ✓ sparkles.base.text.grapheme case");
    // Narrow: module truncated at a '.' boundary with a leading '…'.
    assert(formatResultLine(result, false, false, 24) == " ✓ …text.grapheme case");
    // Too narrow to keep a useful tail: leave the line unmangled.
    assert(formatResultLine(result, false, false, 6) == " ✓ sparkles.base.text.grapheme case");
    // Verbose is never truncated.
    assert(formatResultLine(result, false, true, 10) ==
        " ✓ sparkles.base.text.grapheme case (0.0ns)");
}

/// The line reported for an `@ctfe` test: it already passed during
/// compilation, so the runtime run only records that fact. `width` truncates
/// the module path as in `formatResultLine`.
string formatCtfeLine(in Test test, bool colored, uint width = 0) @safe
{
    const name = test.name;
    string build(string moduleName) @safe =>
        render(colored, i" {cyan ⚙} {dim $(moduleName)} $(name) {dim (compile time)}");
    return fitWidth(&build, test.moduleName.idup, width);
}

@("formatCtfeLine.plain")
@safe
unittest
{
    const test = Test(fullName: "pkg.mod.__unittest_L9_C1", name: "ct");
    assert(formatCtfeLine(test, false) == " ⚙ pkg.mod ct (compile time)");
}

/// The line reported for an `@ctfe` test whose compile-time evaluation
/// failed; the compiler's error trail is printed separately above.
string formatCtfeFailedLine(in Test test, bool colored, uint width = 0) @safe
{
    const name = test.name;
    string build(string moduleName) @safe =>
        render(colored, i" {bold.red ✗} {dim $(moduleName)} {bold $(name)} {dim (compile time)}");
    return fitWidth(&build, test.moduleName.idup, width);
}

@("formatCtfeFailedLine.plain")
@safe
unittest
{
    const test = Test(fullName: "pkg.mod.__unittest_L9_C1", name: "ct");
    assert(formatCtfeFailedLine(test, false) == " ✗ pkg.mod ct (compile time)");
}

/// Details of one caught `Throwable`, indented under the failed test's line.
/// Non-`verbose` traces stop at the first runner frame.
string formatThrown(in Thrown thrown, bool colored, bool verbose) @safe
{
    import std.algorithm.searching : canFind;
    import std.string : lineSplitter;

    string result;
    bool firstLine = true;
    foreach (line; lineSplitter(thrown.message))
    {
        result ~= firstLine
            ? render(colored,
                i"    {red $(thrown.type)} thrown from {bold $(thrown.file):$(thrown.line)}: $(line)\n")
            : render(colored, i"      $(line)\n");
        firstLine = false;
    }
    if (firstLine) // empty message
        result ~= render(colored,
            i"    {red $(thrown.type)} thrown from {bold $(thrown.file):$(thrown.line)}\n");

    result ~= render(colored, i"    {dim --- stack trace ---}\n");
    foreach (frame; thrown.info)
    {
        if (!verbose && frame.canFind("sparkles.test_runner"))
            break;
        result ~= render(colored, i"    {dim $(frame)}\n");
    }
    return result;
}

@("formatThrown.plain")
@safe
unittest
{
    const thrown = Thrown(
        type: "core.exception.AssertError",
        message: "boom\ndetails",
        file: "src/mod.d",
        line: 42,
        info: ["frame0", "sparkles.test_runner.execution.executeTest", "frame2"],
    );
    assert(formatThrown(thrown, false, false) ==
        "    core.exception.AssertError thrown from src/mod.d:42: boom\n" ~
        "      details\n" ~
        "    --- stack trace ---\n" ~
        "    frame0\n");
    assert(formatThrown(thrown, false, true) ==
        "    core.exception.AssertError thrown from src/mod.d:42: boom\n" ~
        "      details\n" ~
        "    --- stack trace ---\n" ~
        "    frame0\n" ~
        "    sparkles.test_runner.execution.executeTest\n" ~
        "    frame2\n");
}

/// Aggregated counts of one run, for the summary line.
struct RunTotals
{
    size_t passed;
    size_t failed;
    size_t ctfePassed;
    size_t benchSkipped;
}

/// The final summary line.
string formatSummary(in RunTotals totals, Duration elapsed, bool colored) @safe
{
    const duration = formatDuration(elapsed);
    auto line = render(colored, i"{bold Summary:} {green $(totals.passed) passed}");

    line ~= totals.failed
        ? render(colored, i", {bold.red $(totals.failed) failed}")
        : render(colored, i", $(totals.failed) failed");

    if (totals.ctfePassed)
        line ~= render(colored, i", {cyan $(totals.ctfePassed) compile-time}");
    if (totals.benchSkipped)
        line ~= render(colored,
            i", {dim $(totals.benchSkipped) benchmarks (run with --bench)}");

    line ~= render(colored, i" in $(duration)");
    return line;
}

@("formatSummary.plain")
@safe
unittest
{
    import core.time : msecs;

    assert(formatSummary(RunTotals(passed: 3, failed: 0), 12.msecs, false) ==
        "Summary: 3 passed, 0 failed in 12.0ms");
    assert(formatSummary(
            RunTotals(passed: 3, failed: 1, ctfePassed: 2, benchSkipped: 1), 12.msecs, false) ==
        "Summary: 3 passed, 1 failed, 2 compile-time, 1 benchmarks (run with --bench) in 12.0ms");
}

/// The benchmark report as a table: name, iterations/sample, median, ±MAD,
/// min, and max ns-per-iteration. Rendered with `core-cli`'s `drawTable` when
/// available, plain space-aligned columns otherwise.
string formatBenchTable(in BenchStats[] rows, bool colored) @system // drawTable is @system
{
    import core.time : nsecs;
    import std.conv : to;

    static string ns(double value) @safe
    {
        import std.format : format;
        import std.math.rounding : lrint;

        // Sub-microsecond values keep fractional nanoseconds (fast operations
        // are often < 1ns/iter); larger ones use the µs/ms/s auto-units.
        return value < 1_000
            ? format!"%.2fns"(value)
            : formatDuration(nsecs(value.lrint));
    }

    string[][] cells = [[
        render(colored, i"{bold benchmark}"),
        render(colored, i"{bold iters}"),
        render(colored, i"{bold median/iter}"),
        render(colored, i"{bold ±dev}"),
        render(colored, i"{bold min}"),
        render(colored, i"{bold max}"),
    ]];
    foreach (ref row; rows)
        cells ~= [
            row.name,
            row.iterations.to!string,
            ns(row.nsPerIterMedian),
            ns(row.nsPerIterDeviation),
            ns(row.nsPerIterMin),
            ns(row.nsPerIterMax),
        ];

    return renderCells(cells);
}

/// Renders table cells with `core-cli`'s `drawTable` when available, plain
/// space-aligned columns otherwise.
package string renderCells(string[][] cells) @system // drawTable is @system
{
    static if (hasCoreCliUi)
    {
        import sparkles.core_cli.ui.table : drawTable;

        return drawTable(cells);
    }
    else
        return alignColumns(cells);
}

/// The `--ctfe-trace` report: compile-time cost of each `@ctfe` test.
string formatCtfeTraceTable(in CtfeTestCost[] costs, bool colored) @system // renderCells
{
    import core.time : usecs;
    import std.conv : text;

    string[][] cells = [[
        render(colored, i"{bold @ctfe test}"),
        render(colored, i"{bold location}"),
        render(colored, i"{bold CTFE time}"),
    ]];
    long totalUs;
    foreach (ref cost; costs)
    {
        const location = text(cost.test.location.file, ':', cost.test.location.line);
        cells ~= [
            cost.test.name,
            location,
            cost.durUs < 0
                ? render(colored, i"{dim n/a}")
                : formatDuration(cost.durUs.usecs),
        ];
        if (cost.durUs > 0)
            totalUs += cost.durUs;
    }
    return renderCells(cells)
        ~ render(colored, i"{bold total CTFE time attributed to @ctfe tests:} $(formatDuration(totalUs.usecs))\n");
}

/// Fallback tabular rendering: two-space-separated left-aligned columns.
/// Column widths are measured in terminal cells via
/// `sparkles.base.text.visibleWidth`, so ANSI escapes count zero and wide CJK /
/// emoji / combining clusters are sized correctly (matching `drawTable`).
package string alignColumns(in string[][] cells) @safe
{
    import std.algorithm.comparison : max;

    size_t[] widths;
    foreach (row; cells)
        foreach (i, cell; row)
        {
            if (i == widths.length)
                widths ~= 0;
            widths[i] = max(widths[i], visibleWidth(cell));
        }

    string result;
    foreach (row; cells)
    {
        foreach (i, cell; row)
        {
            result ~= cell;
            if (i + 1 < row.length)
                foreach (_; visibleWidth(cell) .. widths[i] + 2)
                    result ~= ' ';
        }
        result ~= '\n';
    }
    return result;
}

@("alignColumns.basic")
@safe
unittest
{
    assert(alignColumns([["a", "bb"], ["ccc", "d"]]) ==
        "a    bb\n" ~
        "ccc  d\n");
}

/// Wide (CJK) cells align by terminal cells, not bytes — proving the
/// `visibleWidth` switch (byte-length would over-pad the `世界` column).
@("alignColumns.wideCells")
@safe
unittest
{
    assert(alignColumns([["世界", "z"], ["x", "y"]]) ==
        "世界  z\n" ~
        "x     y\n");
}
