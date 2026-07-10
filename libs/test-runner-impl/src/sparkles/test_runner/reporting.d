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
import sparkles.base.text.width : Align;

import sparkles.test_runner.bench : BenchStats;
import sparkles.test_runner.ctfe_trace : CtfeTestCost;
import sparkles.test_runner.metrics : MetricClass, MetricDescriptor;
import sparkles.test_runner.model : Test, TestLocation, TestResult, Thrown;

/// Whether `sparkles:core-cli` is in the tested package's dependency closure.
/// It cannot be a dub dependency of this package (that would be a cycle when
/// testing `base`/`core-cli` themselves), so its UI niceties are detected by
/// introspection and skipped when absent.
private enum bool hasCoreCliUi = __traits(compiles, {
    import sparkles.core_cli.ui.osc_link : oscLink;
    import sparkles.core_cli.ui.table : drawTable;
    import sparkles.core_cli.ui.progress : ProgressLine;
});

/// Likewise for `core-cli`'s terminal-size query, used to width-truncate result
/// lines. Absent in `base`'s own test build (no `core-cli` there), where it
/// degrades to `0` = unknown = no truncation.
private enum bool hasCoreCliTermCaps = __traits(compiles, {
    import sparkles.core_cli.term_caps : terminalSize;
});

/// Terminal width in cells via `core-cli` when available, else `0` (unknown →
/// callers skip truncation). `0` is also the value on a non-tty (piped output),
/// so redirected runs stay byte-identical to the untruncated form.
/// `stderrStream` measures stderr's terminal instead — the progress spinner
/// draws there, and `dub test -- --bench > file` leaves only stderr on the tty.
package uint detectTerminalWidth(bool stderrStream = false)
{
    static if (hasCoreCliTermCaps)
    {
        import sparkles.core_cli.term_caps : StdStream, terminalSize;

        return terminalSize(stderrStream ? StdStream.stderr : StdStream.stdout).width;
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

/// The benchmark report as a table: name, iterations/sample, median, ±MAD, min,
/// and max ns-per-iteration. Client `Metric`s add one throughput/level column
/// per distinct `(unit, mode)`, and `--perf` counters add IPC, instructions/iter,
/// and branch/cache miss-rate columns — both grown only when present, with an em
/// dash where a row lacks a value. A row with an `error` (a case whose `after`
/// reported failure) renders the message in place of its timings.
///
/// Grouping and sorting are orthogonal. `sortBy` (`"name"`, a metric column
/// name, or empty/`"median/iter"`) orders rows. `groupBy` (a `--group-by` spec:
/// comma-separated name-segment indices) splits the output into one table **per
/// group**: each is titled `benchmark: <group>` over an `implementation:` stub
/// column that lists just the varying segment(s) (the shared group prefix is
/// dropped — DRY), and rows are ordered within the group by `sortBy`. Empty
/// `groupBy` renders the single flat table (byte-identical to the legacy form).
/// See `sparkles.test_runner.metrics.sortOrder`. Rendered with `core-cli`'s
/// `drawTable` when available, plain space-aligned columns otherwise.
string formatBenchTable(in BenchStats[] rows, bool colored, string metricFilter = null,
    string sortBy = null, in string[] groupKeys = null) @system // drawTable is @system
{
    import sparkles.test_runner.metrics : groupKeyDisplay, groupKeyOf,
        labelKeyUnion, sortOrder, visibleMetrics;

    auto order = sortOrder(rows, sortBy, groupKeys);

    // The visible metric columns (client + perf) via the metric catalog.
    // Row order doesn't affect column selection; the default (null) filter
    // reproduces the legacy column set byte-for-byte.
    auto columns = visibleMetrics(rows, metricFilter);

    // The fixed numeric headers plus one label per visible metric column.
    string[] valueHeaders = [
        render(colored, i"{bold iters}"),
        render(colored, i"{bold median/iter}"),
        render(colored, i"{bold ±dev}"),
        render(colored, i"{bold min}"),
        render(colored, i"{bold max}"),
    ];
    foreach (ref col; columns)
        valueHeaders ~= render(colored, i"{bold $(col.header)}");

    // Per-column alignment for `stubCols` leading textual columns followed by
    // the value columns: numeric values right-align, with the four timing
    // columns aligned on the decimal point (same-unit values line up; mixed
    // units still read right).
    Align[] valueAligns(size_t stubCols)
    {
        auto aligns = new Align[stubCols + valueHeaders.length];
        aligns[] = Align.right;
        aligns[0 .. stubCols] = Align.left;
        aligns[stubCols + 1 .. stubCols + 5] = Align.decimal;
        return aligns;
    }

    // The value cells of one row (everything right of the name/label columns):
    // timings then metric cells, or — for an error row — the message padded.
    string[] valueCells(in BenchStats row) @system
    {
        import std.conv : to;
        import sparkles.test_runner.metrics : formatCell, rowCells;

        if (row.error.length)
        {
            string[] errCols = ["—", render(colored, i"{red $(row.error)}")];
            while (errCols.length < valueHeaders.length)
                errCols ~= "—";
            return errCols;
        }

        string[] cols = [
            row.iterations.to!string,
            benchNs(row.nsPerIterMedian),
            benchNs(row.nsPerIterDeviation),
            benchNs(row.nsPerIterMin),
            benchNs(row.nsPerIterMax),
        ];
        auto rc = rowCells(row);
        foreach (ref col; columns)
        {
            string cell = "—"; // this row does not carry this metric
            foreach (ref mc; rc)
                if (mc.name == col.name)
                {
                    cell = formatCell(mc);
                    break;
                }
            cols ~= cell;
        }
        return cols;
    }

    // Ungrouped: one flat table. `name` alone isn't self-describing (rows may all
    // read `asdf`/`jsoniopipe`), so a leading column per label key precedes the
    // `benchmark` (name) column — rows without labels reproduce the legacy table.
    if (groupKeys.length == 0)
    {
        const labelKeys = labelKeyUnion(rows);
        string[] header;
        foreach (key; labelKeys)
            header ~= render(colored, i"{bold $(key)}");
        header ~= render(colored, i"{bold benchmark}");
        header ~= valueHeaders;

        string[][] cells = [header];
        foreach (idx; order)
        {
            string[] labelCols;
            foreach (key; labelKeys)
                labelCols ~= rows[idx].labels.get(key, "");
            cells ~= labelCols ~ rows[idx].name ~ valueCells(rows[idx]);
        }
        return renderCells(cells, valueAligns(labelKeys.length + 1), headerRows: 1);
    }

    // Grouped: one table per contiguous run of equal group key. Each table's stub
    // header spans two rows — `benchmark: <group>` over `implementation:` — and
    // each data row's stub is the `name` (the varying dimension).
    auto aligns = valueAligns(1);

    string result;
    size_t i = 0;
    while (i < order.length)
    {
        const key = groupKeyOf(rows[order[i]].labels, groupKeys);
        const shownKey = groupKeyDisplay(key); // US separator → '/' for the header
        GridCell[][] grid = [
            // Header band: a rowspan-2 stub cell, value headers spanning it too.
            [GridCell(render(colored, i"{dim benchmark:} {bold $(shownKey)}") ~ "\n"
                    ~ render(colored, i"{dim implementation:}"), rowSpan: 2)]
                ~ toGridRow(valueHeaders, rowSpan: 2),
            [], // the second header row is fully covered by the rowspans above
        ];
        while (i < order.length && groupKeyOf(rows[order[i]].labels, groupKeys) == key)
        {
            const row = rows[order[i]];
            grid ~= GridCell(row.name) ~ toGridRow(valueCells(row));
            i++;
        }
        if (result.length)
            result ~= "\n";
        result ~= renderCellGrid(grid, aligns, headerRows: 2);
    }
    return result;
}

@("formatBenchTable.metricColumns")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.typecons : Nullable;
    import sparkles.test_runner.bench : Metric, Unit;
    import sparkles.test_runner.perf : PerfStats;

    BenchStats row;
    row.name = "a";
    row.iterations = 1;
    row.nsPerIterMedian = 1_000_000.0;
    row.metrics = [Metric(Unit("B"), 1000.0, Metric.Mode.rate)];
    PerfStats p;
    p.cycles = 100;
    p.instructions = 200;
    row.perf = p;

    // Default: client rate + the four default perf columns; not the opt-in extras.
    const def = formatBenchTable([row], false);
    assert(def.canFind("B/s") && def.canFind("IPC") && def.canFind("cache-miss"));
    assert(!def.canFind("cycles/iter"));

    // A glob filter narrows to the requested columns.
    const filtered = formatBenchTable([row], false, "ipc,cycles");
    assert(filtered.canFind("IPC") && filtered.canFind("cycles/iter"));
    assert(!filtered.canFind("B/s") && !filtered.canFind("cache-miss"));
}

@("formatBenchTable.grouped")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.string : indexOf;

    static BenchStats row(string engine, string dataset, double median)
    {
        return BenchStats(name: engine,
            labels: ["dataset": dataset, "operation": "parse"], iterations: 1,
            nsPerIterMedian: median);
    }

    BenchStats[3] rows = [
        row("asdf", "canada", 30),
        row("mir-ion", "canada", 10),
        row("asdf", "twitter", 20),
    ];

    // --group-by=dataset,operation → one table per group; the stub header carries
    // the group title and an `implementation:` label, rows list the engine `name`.
    const rendered = formatBenchTable(rows, false, null, null, ["dataset", "operation"]);
    assert(rendered.canFind("benchmark: canada/parse"));
    assert(rendered.canFind("benchmark: twitter/parse"));
    assert(rendered.canFind("implementation:"));
    assert(rendered.canFind("mir-ion"));
    // Two tables → two top borders.
    assert(rendered.indexOf("╭") != rendered.indexOf("╭", rendered.indexOf("╭") + 1));
    // Within the canada group, the faster engine (mir-ion, 10) precedes asdf (30).
    assert(rendered.indexOf("mir-ion") < rendered.indexOf("asdf"));
}

@("formatBenchTable.flatLabelColumns")
@system
unittest
{
    import std.algorithm.searching : canFind;

    // Ungrouped: label keys become leading columns so the table stays
    // self-describing when `name` alone is just the engine.
    BenchStats[2] rows = [
        BenchStats(name: "asdf", labels: ["dataset": "canada"], iterations: 1),
        BenchStats(name: "mir-ion", labels: ["dataset": "twitter"], iterations: 1),
    ];
    const rendered = formatBenchTable(rows, false); // no --group-by
    assert(rendered.canFind("dataset") && rendered.canFind("benchmark"));
    assert(rendered.canFind("canada") && rendered.canFind("asdf"));
    // A label-less row set reproduces the plain flat table (no leading columns).
    BenchStats plain;
    plain.name = "sum/64";
    plain.iterations = 1;
    assert(formatBenchTable([plain], false).canFind("benchmark"));
}

/// The `--list-metrics` report: every catalog metric with its column label,
/// class (quantitative/diagnostic), source, and whether it is producible now.
string formatMetricCatalog(in MetricDescriptor[] cat, bool colored) @system // renderCells
{
    string[][] cells = [[
        render(colored, i"{bold metric}"),
        render(colored, i"{bold column}"),
        render(colored, i"{bold class}"),
        render(colored, i"{bold source}"),
        render(colored, i"{bold available}"),
    ]];
    foreach (ref d; cat)
        cells ~= [
            d.name,
            d.header,
            d.cls == MetricClass.quantitative ? "quantitative" : "diagnostic",
            d.source,
            d.available ? "yes" : "no",
        ];
    return renderCells(cells, headerRows: 1);
}

/// Renders table cells with `core-cli`'s `drawTable` when available, plain
/// space-aligned columns otherwise. `aligns`/`headerRows` describe per-column
/// alignment and the header-rule row count; `Align` lives in `base`, so this
/// signature stays valid without `core-cli` (`TableProps` is built strictly
/// inside the capability gate), and the fallback honors right/decimal columns
/// as plain right alignment.
package string renderCells(
    string[][] cells, in Align[] aligns = null, size_t headerRows = 0)
@system // drawTable is @system
{
    static if (hasCoreCliUi)
    {
        import sparkles.core_cli.ui.table : drawTable, TableProps;

        return drawTable(cells,
            TableProps(headerRows: headerRows, columnAligns: aligns.dup));
    }
    else
        return alignColumns(cells, aligns);
}

/// A duration/count formatted for a benchmark timing column: sub-microsecond
/// values keep fractional nanoseconds (fast operations are often < 1ns/iter),
/// larger ones use the µs/ms/s auto-units.
private string benchNs(double value) @safe
{
    import core.time : nsecs;
    import std.format : format;
    import std.math.rounding : lrint;

    return value < 1_000
        ? format!"%.2fns"(value)
        : formatDuration(nsecs(value.lrint));
}

/// A span-capable table cell, decoupled from `core-cli`'s `Cell` so the type is
/// usable even in builds without `core-cli` (where it degrades to plain text).
package struct GridCell
{
    string content;
    size_t colSpan = 1;
    size_t rowSpan = 1;
}

/// Lifts a row of plain strings to `GridCell`s, all sharing `rowSpan` (used to
/// make value headers span the two-row group-table header band).
private GridCell[] toGridRow(in string[] contents, size_t rowSpan = 1) @safe
{
    import std.algorithm.iteration : map;
    import std.array : array;

    return contents.map!(c => GridCell(c, rowSpan: rowSpan)).array;
}

/// Renders a span-capable `GridCell[][]` grid via `core-cli`'s `drawTable` when
/// available (honoring spans, `headerRows`, and per-column alignment), or a
/// plain space-aligned fallback that ignores spans otherwise.
private string renderCellGrid(GridCell[][] grid, in Align[] aligns, size_t headerRows) @system
{
    static if (hasCoreCliUi)
    {
        import sparkles.core_cli.ui.table : Cell, drawTable, TableProps;

        auto cells = new Cell[][](grid.length);
        foreach (r, row; grid)
        {
            cells[r] = new Cell[row.length];
            foreach (c, gc; row)
                cells[r][c] = Cell(gc.content, colSpan: gc.colSpan, rowSpan: gc.rowSpan);
        }

        return drawTable(cells, TableProps(headerRows: headerRows, columnAligns: aligns.dup));
    }
    else
        return renderCellGridPlain(grid, headerRows);
}

/// The span-less plain rendering used when `core-cli`'s `drawTable` is absent
/// (e.g. `base`'s own bench build). Emits each cell's text, dropping empty
/// (fully covered) rows. A multi-line header cell — the grouped stub
/// `"benchmark: <key>\nimplementation:"` — would otherwise put a newline inside a
/// single `alignColumns` column and break the rectangular layout, so its leading
/// lines are hoisted into a heading above the table and only the last line stays
/// as the column header. Always compiled (not behind the `hasCoreCliUi`
/// static-if) so it stays unit-testable in this package's own build.
private string renderCellGridPlain(GridCell[][] grid, size_t headerRows) @safe
{
    import std.string : lastIndexOf;

    string heading;
    string[][] flat;
    foreach (r, row; grid)
    {
        if (row.length == 0)
            continue; // fully covered by a rowspan above
        string[] cells;
        foreach (gc; row)
        {
            string content = gc.content;
            if (r < headerRows)
            {
                const nl = content.lastIndexOf('\n');
                if (nl >= 0)
                {
                    heading ~= (heading.length ? "\n" : "") ~ content[0 .. nl];
                    content = content[nl + 1 .. $];
                }
            }
            cells ~= content;
        }
        flat ~= cells;
    }
    return (heading.length ? heading ~ "\n" : "") ~ alignColumns(flat);
}

@("reporting.renderCellGridPlain.hoistsMultiLineStub")
@safe
unittest
{
    import std.algorithm.searching : canFind;
    import std.string : splitLines, startsWith;

    // The grouped header is a rowspan-2 stub "benchmark: k\nimplementation:" over
    // an empty (covered) second row. The plain fallback must hoist the group line
    // above the table and keep every table row rectangular (no embedded newline).
    GridCell[][] grid = [
        [GridCell("benchmark: twitter\nimplementation:", rowSpan: 2), GridCell("iters", rowSpan: 2)],
        [],
        [GridCell("wired"), GridCell("5")],
    ];
    const rendered = renderCellGridPlain(grid, 2);
    assert(rendered.startsWith("benchmark: twitter\n"), rendered);
    auto lines = rendered.splitLines;
    // The group heading is hoisted, not fused into a data column.
    assert(!lines[1 .. $].canFind!(l => l.canFind("benchmark:")), rendered);
    assert(lines.canFind!(l => l.canFind("implementation:")), rendered);
    assert(lines.canFind!(l => l.canFind("wired")), rendered);
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
    // The CTFE-time column is numeric; the test name and location are textual.
    return renderCells(cells, [Align.left, Align.left, Align.right], headerRows: 1)
        ~ render(colored, i"{bold total CTFE time attributed to @ctfe tests:} $(formatDuration(totalUs.usecs))\n");
}

/// Fallback tabular rendering: two-space-separated columns, left-aligned by
/// default; `aligns` entries of `right`/`decimal` pad before the cell instead
/// (decimal degrades to plain right — there is no shared dot position without
/// the full grid). Column widths are measured in terminal cells via
/// `sparkles.base.text.visibleWidth`, so ANSI escapes count zero and wide CJK /
/// emoji / combining clusters are sized correctly (matching `drawTable`).
package string alignColumns(in string[][] cells, in Align[] aligns = null) @safe
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

    bool rightish(size_t i)
        => i < aligns.length && (aligns[i] == Align.right || aligns[i] == Align.decimal);

    string result;
    foreach (row; cells)
    {
        foreach (i, cell; row)
        {
            if (rightish(i))
                foreach (_; visibleWidth(cell) .. widths[i])
                    result ~= ' ';
            result ~= cell;
            if (i + 1 < row.length)
            {
                const used = rightish(i) ? widths[i] : visibleWidth(cell);
                foreach (_; used .. widths[i] + 2)
                    result ~= ' ';
            }
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

@("alignColumns.rightAndDecimalFallback")
@safe
unittest
{
    // right/decimal columns pad before the cell; decimal degrades to right.
    assert(alignColumns([["a", "22"], ["ccc", "4"]],
            [Align.left, Align.right]) ==
        "a    22\n" ~
        "ccc   4\n");
    assert(alignColumns([["1.5"], ["12.25"]], [Align.decimal]) ==
        "  1.5\n" ~
        "12.25\n");
}

// ─────────────────────────────────────────────────────────────────────────────
// Live benchmark progress (stderr, POSIX)
// ─────────────────────────────────────────────────────────────────────────────

/// Whether a live spinner should animate: stderr is an interactive terminal,
/// colours aren't disabled (`--no-colours` / `$NO_COLOR`), and the terminal
/// isn't `TERM=dumb` (no cursor-control escapes). POSIX-only — `false`
/// elsewhere. Independent of stdout, so results piped to a file still show
/// progress on the terminal.
package bool stderrIsTty(bool noColours)
{
    import std.process : environment;

    if (noColours || environment.get("NO_COLOR", "").length != 0
        || environment.get("TERM", "") == "dumb")
        return false;
    version (Posix)
    {
        import core.sys.posix.unistd : isatty, STDERR_FILENO;

        return isatty(STDERR_FILENO) != 0;
    }
    else
        return false;
}

/// Raw, unbuffered write to stderr's fd — `@nogc nothrow` (unlike
/// `std.stdio.stderr.write`), so it is callable from the `@safe nothrow @nogc`
/// progress hook. No-op on non-POSIX.
private void writeStderr(scope const(char)[] s) @trusted nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : write, STDERR_FILENO;

        if (s.length)
            cast(void) write(STDERR_FILENO, s.ptr, s.length);
    }
}

/// `s` truncated to at most `maxCells` display columns, measured in true
/// terminal cells via grapheme clustering (wide CJK/emoji count 2, combining
/// marks 0) — a code-point approximation lets a wide-glyph case name overflow
/// the terminal, wrap, and leave a ghost row the one-line CR+erase can't
/// clear. Never splits a cluster.
private const(char)[] clampCells(return scope const(char)[] s, size_t maxCells)
    @safe pure nothrow @nogc
{
    size_t cells, bytes;
    foreach (c; s.byGraphemeCluster)
    {
        if (cells + c.width > maxCells)
            break;
        cells += c.width;
        bytes += c.slice.length;
    }
    return s[0 .. bytes];
}

@("reporting.clampCells")
@safe pure nothrow @nogc
unittest
{
    assert(clampCells("hello", 80) == "hello");
    assert(clampCells("hello", 3) == "hel");
    assert(clampCells("hello", 0) == "");
    assert(clampCells("aéb", 2) == "aé"); // é is 2 bytes / 1 cell, not split
    // Wide glyphs cost 2 cells: a clamp mid-glyph drops the whole glyph.
    assert(clampCells("測試x", 5) == "測試x");
    assert(clampCells("測試x", 4) == "測試");
    assert(clampCells("測試", 3) == "測");
    assert(clampCells("a🚀b", 3) == "a🚀");
}

/// Live single-line benchmark progress on stderr: redraws
/// `⠹ 12/40 mir-ion/canada/parse` in place as each case begins. `tick` is the
/// `@safe nothrow @nogc` seam handed to `runBenchmark` as `onCaseStart` (so it
/// never constrains a benchmark body's attributes); it reuses `core-cli`'s
/// `ProgressLine` when available and is a no-op without `core-cli` (base's own
/// bench build) or when `!active`.
package struct BenchProgress
{
    import core.time : MonoTime;

    size_t total;            /// case denominator from the enumerate pass
    bool active;             /// stderr is an interactive tty (colours on)
    uint width;              /// terminal width in cells (0 = unknown → fixed cap)
    private size_t done;
    private size_t frame;
    private MonoTime started;

    /// Advance to the next case and redraw the line.
    void tick(scope const(char)[] name) @safe nothrow @nogc
    {
        if (!active)
            return;
        done++;
        frame++;

        static if (hasCoreCliUi)
        {
            import sparkles.base.smallbuffer : SmallBuffer;
            import sparkles.base.term_control : CtlSeq;
            import sparkles.core_cli.ui.progress : ProgressLine;

            if (started == MonoTime.init)
                started = MonoTime.currTime;
            const shown = done > total ? done : total; // never render done > total
            const elapsed = MonoTime.currTime - started;

            // Measure the (uncoloured) prefix so the label gets the terminal's
            // remaining columns; clamp it there rather than to a fixed 80 that
            // wraps a narrow terminal and leaves a ghost row the CR+eraseLine
            // (one physical line) can't erase. width==0 (unknown/piped) keeps the
            // old fixed cap, so nothing changes there.
            SmallBuffer!(char, 64) plainPrefix;
            ProgressLine(frame, done, shown, false, elapsed).toString(plainPrefix);
            const prefixCells = visibleWidth(plainPrefix[]);
            const budget = width == 0
                ? 80
                : (width > prefixCells + 1 ? width - prefixCells - 1 : 0);

            SmallBuffer!(char, 256) buf;
            buf ~= cast(string) CtlSeq.carriageReturn;
            buf ~= cast(string) CtlSeq.eraseLine;
            ProgressLine(frame, done, shown, true, elapsed).toString(buf);
            if (budget > 0)
            {
                buf ~= ' ';
                buf ~= clampCells(name, budget);
            }
            writeStderr(buf[]);
        }
    }

    /// Erase the spinner line (before printing a table, and at the end).
    void clear() @safe nothrow @nogc
    {
        if (!active)
            return;
        static if (hasCoreCliUi)
        {
            import sparkles.base.term_control : CtlSeq;

            enum eraseSeq = cast(string) CtlSeq.carriageReturn
                ~ cast(string) CtlSeq.eraseLine;
            writeStderr(eraseSeq);
        }
    }
}
