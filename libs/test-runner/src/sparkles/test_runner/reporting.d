/**
 * Rendering of test results, benchmark tables, and run summaries.
 *
 * All functions are pure string producers parameterized by `colored`, so the
 * exact output is unit-testable; the runner streams them to `stdout`.
 */
module sparkles.test_runner.reporting;

import core.interpolation : InterpolationFooter, InterpolationHeader;
import core.time : Duration;

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

/// The per-test result line: ` ✓ module name` / ` ✗ module name`, plus
/// duration and location when `verbose`.
string formatResultLine(in TestResult result, bool colored, bool verbose) @safe
{
    const test = result.test;
    const moduleName = test.moduleName;
    auto line = result.succeeded
        ? render(colored, i" {green ✓} {dim $(moduleName)} $(test.name)")
        : render(colored, i" {bold.red ✗} {dim $(moduleName)} {bold $(test.name)}");

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

/// The line reported for an `@ctfe` test: it already passed during
/// compilation, so the runtime run only records that fact.
string formatCtfeLine(in Test test, bool colored) @safe
{
    const moduleName = test.moduleName;
    return render(colored, i" {cyan ⚙} {dim $(moduleName)} $(test.name) {dim (compile time)}");
}

@("formatCtfeLine.plain")
@safe
unittest
{
    const test = Test(fullName: "pkg.mod.__unittest_L9_C1", name: "ct");
    assert(formatCtfeLine(test, false) == " ⚙ pkg.mod ct (compile time)");
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
/// Column widths ignore ANSI escapes so colored cells stay aligned.
package string alignColumns(in string[][] cells) @safe
{
    import std.algorithm.comparison : max;

    static size_t visibleLength(string cell) @safe
    {
        size_t length;
        for (size_t i = 0; i < cell.length;)
        {
            if (cell[i] == '\x1b')
            {
                i++;
                if (i < cell.length && cell[i] == '[')
                {
                    i++;
                    while (i < cell.length && !(cell[i] >= '@' && cell[i] <= '~'))
                        i++;
                    if (i < cell.length)
                        i++;
                }
                continue;
            }
            // One column per code point (non-continuation UTF-8 byte).
            if ((cell[i] & 0xC0) != 0x80)
                length++;
            i++;
        }
        return length;
    }

    size_t[] widths;
    foreach (row; cells)
        foreach (i, cell; row)
        {
            if (i == widths.length)
                widths ~= 0;
            widths[i] = max(widths[i], visibleLength(cell));
        }

    string result;
    foreach (row; cells)
    {
        foreach (i, cell; row)
        {
            result ~= cell;
            if (i + 1 < row.length)
                foreach (_; visibleLength(cell) .. widths[i] + 2)
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
