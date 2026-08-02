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
import sparkles.test_runner.capability : allCapabilities, BackendCapabilities,
    capabilityName, has, reasonFor;
import sparkles.test_runner.ctfe_trace : CtfeTestCost;
import sparkles.test_runner.metrics : MetricClass, MetricDescriptor;
import sparkles.test_runner.model : Test, TestLocation, TestResult, Thrown;
import sparkles.test_runner.workload : WorkloadWindow;

/// Whether the `sparkles:ui` components are in the tested package's dependency
/// closure. This package *does* depend on them, but `base`/`core-cli`/`test-utils`
/// source-include the runner rather than depending on it (that would be a cycle
/// when testing themselves), and in those builds the toolkit is absent — so the
/// UI niceties are detected by introspection and skipped when missing. Keep this
/// a guard, never an unconditional import: `docs/specs/ui/migration.md` `MIG6`.
private enum bool hasUiComponents = __traits(compiles, {
    import sparkles.ui.components.osc_link : oscLink;
    import sparkles.ui.components.table : drawTable;
    import sparkles.ui.components.progress : ProgressLine;
});

/// Likewise for the terminal-size query used to width-truncate result lines.
/// It lives in `sparkles:base`, so it is available wherever the runner is —
/// the guard remains only so a `-betterC`/freestanding build can drop it.
private enum bool hasTermCaps = __traits(compiles, {
    import sparkles.base.term_caps : terminalSize;
});

/// Terminal width in cells via `core-cli` when available, else `0` (unknown →
/// callers skip truncation). `0` is also the value on a non-tty (piped output),
/// so redirected runs stay byte-identical to the untruncated form.
/// `stderrStream` measures stderr's terminal instead — the progress spinner
/// draws there, and `dub test -- --bench > file` leaves only stderr on the tty.
package uint detectTerminalWidth(bool stderrStream = false)
{
    static if (hasTermCaps)
    {
        import sparkles.base.term_caps : StdStream, terminalSize;

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
    static if (hasUiComponents)
    {
        if (colored)
        {
            import std.path : absolutePath;
            import sparkles.ui.components.osc_link : oscLink;

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
    const skipped = result.skipped;

    string build(string moduleName) @safe
    {
        if (skipped)
            return render(colored, i" {yellow ⊘} {dim $(moduleName)} $(name)");
        return succeeded
            ? render(colored, i" {green ✓} {dim $(moduleName)} $(name)")
            : render(colored, i" {bold.red ✗} {dim $(moduleName)} {bold $(name)}");
    }

    // Truncation applies only to the compact (non-verbose) line. `.idup` drops
    // the conservative `return scope` on `moduleName` (it is GC-backed already).
    auto line = verbose ? build(test.moduleName) : fitWidth(&build, test.moduleName.idup, width);

    // The reason is the point of surfacing a skip — always shown.
    if (skipped && result.skipReason.length)
        line ~= render(colored, i" {dim ($(result.skipReason))}");

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
    size_t skipped; /// tests that called `skipTest` — neither passed nor failed
    size_t ctfePassed;
    size_t benchSkipped;
    size_t workloadSkipped;
}

/// The final summary line.
string formatSummary(in RunTotals totals, Duration elapsed, bool colored) @safe
{
    const duration = formatDuration(elapsed);
    auto line = render(colored, i"{bold Summary:} {green $(totals.passed) passed}");

    line ~= totals.failed
        ? render(colored, i", {bold.red $(totals.failed) failed}")
        : render(colored, i", $(totals.failed) failed");

    // Only when non-zero, so existing pinned outputs stay byte-identical.
    if (totals.skipped)
        line ~= render(colored, i", {yellow $(totals.skipped) skipped}");
    if (totals.ctfePassed)
        line ~= render(colored, i", {cyan $(totals.ctfePassed) compile-time}");
    if (totals.benchSkipped)
        line ~= render(colored,
            i", {dim $(totals.benchSkipped) benchmarks (run with --bench)}");
    if (totals.workloadSkipped)
        line ~= render(colored,
            i", {dim $(totals.workloadSkipped) workloads (run with --bench)}");

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
    assert(formatSummary(RunTotals(passed: 3, failed: 0, skipped: 2), 12.msecs, false) ==
        "Summary: 3 passed, 0 failed, 2 skipped in 12.0ms");
    assert(formatSummary(
            RunTotals(passed: 1, failed: 0, benchSkipped: 2, workloadSkipped: 1),
            12.msecs, false) ==
        "Summary: 1 passed, 0 failed, 2 benchmarks (run with --bench), "
        ~ "1 workloads (run with --bench) in 12.0ms");
}

@("formatResultLine.skipped")
@safe
unittest
{
    auto result = TestResult(
        test: Test(fullName: "pkg.mod.__unittest_L1_C1", name: "case"),
        skipped: true,
        skipReason: "no perf counters",
    );
    assert(formatResultLine(result, false, false) == " ⊘ pkg.mod case (no perf counters)");
}

/// The benchmark report as a table: name, sample count `n`, median (with ±MAD
/// folded into the same cell), min, and max ns-per-iteration. Client `Metric`s
/// add one throughput/level column per distinct `(unit, mode)`, and `--perf`
/// counters add instructions/iter (first, the deterministic anchor), IPC, and
/// branch/cache miss-rate columns — both grown only when present, with an em
/// dash where a row lacks a value. When any row carries an `error` (a case whose
/// `after` reported failure), a trailing `notes` column appears and the message
/// wraps there, its timing/metric cells left as em dashes.
///
/// Grouping and sorting are orthogonal. `sortBy` (`"name"`, a metric column
/// name, or empty/`"median/iter"`) orders rows within each group; error rows
/// sort last under every order. `groupKeys` (case **label** keys, from
/// `--group-by`) splits the output into one table **per group** of equal
/// label values: each is titled `benchmark: <group>` over an
/// `implementation` stub column listing the row `name`, with a column per
/// remaining (non-grouped) label key. Empty `groupKeys` renders the single
/// flat table, label keys as leading columns, rows in ascending median order.
/// See `sparkles.test_runner.metrics.sortOrder`/`groupKeyOf`. Rendered with
/// `core-cli`'s `drawTable` when available, plain space-aligned columns
/// otherwise.
///
/// All tables of one call share their column geometry (the union of their
/// natural widths). `geometry`, when given, carries that geometry **across**
/// calls: the streaming runner renders one table per group as it finishes, and
/// the floors keep consecutive tables from re-deriving narrower columns —
/// columns only widen during a run. The recorded header row is the signature:
/// a table with different columns resets the carry instead of misapplying the
/// floors positionally.
string formatBenchTable(in BenchStats[] rows, bool colored, string metricFilter = null,
    string sortBy = null, in string[] groupKeys = null,
    TableGeometry* geometry = null) @system // drawTable is @system
{
    auto models = buildBenchTables(rows, colored, metricFilter, sortBy, groupKeys);
    const floors = applyGeometry(geometry, models);

    string result;
    foreach (ref m; models)
    {
        if (result.length)
            result ~= "\n";
        result ~= renderCells(m.cells, m.aligns, headerRows: 1, title: m.title,
            minWidths: floors, maxWidths: m.maxWidths);
    }
    return result;
}

/// One renderable bench table: the (possibly styled) `title` — empty for the
/// flat table — the header row followed by the data rows, and the per-column
/// alignment.
package struct BenchTableModel
{
    string title;
    string[][] cells; /// `[0]` is the header row
    Align[] aligns;
    size_t[] maxWidths; /// per-column content caps (0 = uncapped); wraps the notes column
}

/// The error/skip message of a failed case rides in a trailing `notes` column
/// that soft-wraps at this content width, instead of distorting a timing cell.
private enum benchNotesMaxWidth = 48;

/// The in-flight case rides through the bench-table model as a pseudo error row
/// carrying this sentinel (so the group's title/header/columns exist before the
/// first real row lands); the ticker replaces its cells wholesale, and the
/// notes-column gate excludes it so an all-green group never grows a notes
/// column mid-run.
package enum benchInflightSentinel = "\x01measuring";

/// Column geometry carried across `formatBenchTable` calls (caller-owned; see
/// the `geometry` parameter above).
package struct TableGeometry
{
    string[] header;  /// the header row the floors were derived under
    size_t[] floors;  /// per-column content-width floors, in visible cells
}

/// The column floors for rendering `models`: the union of their natural
/// widths, merged into (and carried forward by) `geometry` when given —
/// resetting the carry when the header row (the column signature) changed.
private size_t[] applyGeometry(TableGeometry* geometry, in BenchTableModel[] models)
    @safe
{
    size_t[] floors;
    foreach (ref m; models)
        floors = mergeWidths(floors, contentWidths(m.cells));
    if (geometry !is null && models.length)
    {
        if (geometry.header != models[0].cells[0])
            geometry.floors = null; // different columns: the carry is stale
        geometry.floors = mergeWidths(geometry.floors, floors);
        geometry.header = models[0].cells[0].dup;
        floors = geometry.floors;
    }
    return floors;
}

/// The table models `formatBenchTable` renders — split out so a live view can
/// render the same rows through `drawTableLines` with identical geometry.
package BenchTableModel[] buildBenchTables(in BenchStats[] rows, bool colored,
    string metricFilter = null, string sortBy = null, in string[] groupKeys = null)
@system
{
    import sparkles.test_runner.metrics : groupKeyDisplay, groupKeyOf,
        labelKeyUnion, sortOrder, visibleMetrics;

    auto order = sortOrder(rows, sortBy, groupKeys);

    // The visible metric columns (client + perf) via the metric catalog.
    // Row order doesn't affect column selection; the default (null) filter
    // reproduces the legacy column set byte-for-byte.
    auto columns = visibleMetrics(rows, metricFilter);

    // A real error/skip row (not the ticker's in-flight sentinel) earns a
    // trailing, wrapping `notes` column; an all-green table keeps the legacy
    // column set and stays byte-identical to the piped flush.
    import std.algorithm.searching : any;

    const hasNotes = rows.any!(r => r.error.length && r.error != benchInflightSentinel);

    // The fixed numeric headers plus one label per visible metric column, then a
    // trailing `notes` column when any row failed. `median/iter` folds in the
    // deviation ("30.00ns ±1.00ns"); `n` is the sample count `--bench-min-time`
    // grows.
    string[] valueHeaders = [
        render(colored, i"{bold n}"),
        render(colored, i"{bold median/iter}"),
        render(colored, i"{bold min}"),
        render(colored, i"{bold max}"),
    ];
    foreach (ref col; columns)
        valueHeaders ~= render(colored, i"{bold $(col.header)}");
    if (hasNotes)
        valueHeaders ~= render(colored, i"{bold notes}");

    // Per-column alignment for `stubCols` leading textual columns followed by
    // the value columns: the integral `n` column right-aligns; the merged
    // `median/iter` cell also right-aligns (its trailing `±dev` denies a clean
    // shared dot); `min`/`max` and the metric columns align on the decimal point
    // (same-unit values line up; mixed units/magnitudes still read right). A
    // metric column with no dotted value — a syscall count, or all em dashes —
    // degrades to plain right; the trailing `notes` column left-aligns (it wraps).
    Align[] valueAligns(size_t stubCols)
    {
        auto aligns = new Align[stubCols + valueHeaders.length];
        aligns[] = Align.decimal;
        aligns[0 .. stubCols] = Align.left;
        aligns[stubCols] = Align.right;     // n (sample count)
        aligns[stubCols + 1] = Align.right; // median/iter (merged ±dev)
        if (hasNotes)
            aligns[$ - 1] = Align.left;     // notes wraps
        return aligns;
    }

    // A notes column caps its content width (and wraps on the drawTable path);
    // every other column stays uncapped. Sized to the full table column count.
    size_t[] notesMaxWidths(size_t totalCols)
    {
        if (!hasNotes)
            return null;
        auto w = new size_t[totalCols];
        w[$ - 1] = benchNotesMaxWidth;
        return w;
    }

    // The value cells of one row (everything right of the name/label columns):
    // n, merged median, min, max, then metric cells — or, for an error row, em
    // dashes with the message in the trailing notes column.
    string[] valueCells(in BenchStats row) @system
    {
        import std.conv : text, to;
        import sparkles.test_runner.metrics : formatCell, rowCells;

        if (row.error.length)
        {
            auto cells = new string[valueHeaders.length];
            cells[] = "—";
            if (row.error == benchInflightSentinel)
                cells[0] = row.error; // parked in `n`; the ticker overwrites it
            else
                // A real failure: the message rides in the trailing notes column
                // (hasNotes is true here), every timing/metric cell an em dash.
                cells[$ - 1] = row.skipped
                    ? render(colored, i"{yellow $(row.error)}")
                    : render(colored, i"{red $(row.error)}");
            return cells;
        }

        // `n` is the sample count (what `--bench-min-time` grows); a batched case
        // running several iterations per sample reads `samples×iterations`.
        const nCell = row.iterations > 1
            ? text(row.samples, "×", row.iterations)
            : (row.samples ? row.samples.to!string : "—");
        string[] cols = [
            nCell,
            benchNs(row.nsPerIterMedian) ~ " ±" ~ benchNs(row.nsPerIterDeviation),
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
        if (hasNotes)
            cols ~= ""; // a passing row carries no note
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
        auto aligns = valueAligns(labelKeys.length + 1);
        return [BenchTableModel(null, cells, aligns, notesMaxWidths(aligns.length))];
    }

    // Grouped: one table per contiguous run of equal group key, titled
    // `benchmark: <group>` over an `implementation` stub column whose rows are
    // the `name` (the varying dimension). Label keys NOT in --group-by still
    // discriminate rows (three `jsoniopipe` rows may be
    // parse/serialize/validate), so they get columns after the stub, exactly as
    // the ungrouped path prepends them.
    string[] restKeys;
    foreach (key; labelKeyUnion(rows))
    {
        import std.algorithm.searching : canFind;

        if (!groupKeys.canFind(key))
            restKeys ~= key;
    }
    auto aligns = valueAligns(1 + restKeys.length);

    string[] restHeaders;
    foreach (key; restKeys)
        restHeaders ~= render(colored, i"{bold $(key)}");

    BenchTableModel[] models;
    size_t i = 0;
    while (i < order.length)
    {
        const key = groupKeyOf(rows[order[i]].labels, groupKeys);
        const shownKey = groupKeyDisplay(key); // US separator → '/' for the header
        // The group name rides in the table title (spliced into the top border
        // by `drawTable`, hoisted as a heading line by the plain fallback), so
        // the header is one ordinary row — `implementation` is a header cell
        // like any other (bold, no label colon).
        const title = render(colored, i"{dim benchmark:} {bold $(shownKey)}");
        string[][] cells = [
            render(colored, i"{bold implementation}") ~ restHeaders ~ valueHeaders,
        ];
        while (i < order.length && groupKeyOf(rows[order[i]].labels, groupKeys) == key)
        {
            const row = rows[order[i]];
            string[] restVals;
            foreach (k; restKeys)
                restVals ~= row.labels.get(k, "");
            cells ~= row.name ~ restVals ~ valueCells(row);
            i++;
        }
        models ~= BenchTableModel(title, cells, aligns, notesMaxWidths(aligns.length));
    }
    return models;
}

/// Renders `@workload` windows as their own table — window totals and the
/// wall-clock decomposition, deliberately separate from the per-iteration
/// bench tables (a window's fields mean different things).
string formatWorkloadTable(in WorkloadWindow[] rows, bool colored) @system
{
    auto model = buildWorkloadTable(rows, colored);
    return renderCells(model.cells, model.aligns, headerRows: 1, title: model.title);
}

/// The workload table's model: `workload | reps | wall | cpu usr | cpu krn |
/// runq | other`, then — when PSI is readable — an `io-stall` column placed
/// AFTER `other` (the placement is the claim: a system-wide stall integral
/// is context next to the decomposition, not a part of its sum), then
/// window-total columns for each source any row carries (perf, tier-0,
/// syscalls, raw), then a dim `note` column when any window has a
/// disclosure. An unattributable component is an em dash; scaled perf
/// windows render `≈`-marked like the bench tables. No disk column: thread
/// attribution of disk stall lands with M8's cgroup-scoped PSI.
package BenchTableModel buildWorkloadTable(in WorkloadWindow[] rows, bool colored) @system
{
    import std.algorithm.searching : canFind;
    import std.conv : to;
    import std.math : isNaN;
    import sparkles.test_runner.metrics : isEstimatedScale, scaled;
    import sparkles.test_runner.perf : ipc;
    import sparkles.test_runner.raw : rawHeader;

    const hasPerf = rows.canFind!(r => !r.perf.isNull);
    const hasTier0 = rows.canFind!(r => !r.tier0.isNull);
    const hasSyscalls = rows.canFind!(r => !r.syscalls.isNull);
    const hasRaw = rows.canFind!(r => !r.raw.isNull);
    // Value-gated, not presence-gated: a run whose io reads all failed
    // after the open probe would otherwise render an all-em-dash column —
    // exactly the "always-empty column is noise" rationale above.
    const hasPsi = rows.canFind!(r => !r.psi.isNull && !r.psi.get.ioSomeNs.isNaN);
    const hasNote = rows.canFind!(r => r.wall.note.length > 0);

    // Named syscall / raw selector columns come from the shared open groups,
    // identical across rows — the first carrier defines them.
    const(string)[] syscallNames;
    const(string)[] rawSelectors;
    foreach (ref r; rows)
    {
        if (syscallNames.length == 0 && !r.syscalls.isNull)
            syscallNames = r.syscalls.get.named;
        if (rawSelectors.length == 0 && !r.raw.isNull)
            rawSelectors = r.raw.get.selectors;
    }

    string[] headers = ["workload", "reps", "wall", "cpu usr", "cpu krn",
        "runq", "other"];
    if (hasPsi)
        headers ~= "io-stall";
    if (hasPerf)
        headers ~= ["instr", "cycles", "ipc", "pg-flt"];
    if (hasTier0)
        headers ~= ["maj-flt", "rd-bytes", "wr-bytes"];
    if (hasSyscalls)
    {
        headers ~= "syscalls";
        foreach (name; syscallNames)
            headers ~= "sc:" ~ name;
    }
    if (hasRaw)
        foreach (sel; rawSelectors)
            headers ~= rawHeader(sel);
    if (hasNote)
        headers ~= "note";

    auto aligns = new Align[headers.length];
    aligns[] = Align.decimal;
    aligns[0] = Align.left;
    aligns[1] = Align.right;
    if (hasNote)
        aligns[$ - 1] = Align.left;

    static string durCell(double ns) @safe
        => ns.isNaN ? "—" : benchNs(ns);

    // Header cells are bolded here like every other runner table —
    // `renderCells` treats `headerRows` as separator geometry only.
    auto headerCells = new string[headers.length];
    foreach (i, h; headers)
        headerCells[i] = render(colored, i"{bold $(h)}");
    string[][] cells = [headerCells];
    foreach (ref r; rows)
    {
        if (r.error.length)
        {
            const message = r.skipped
                ? render(colored, i"{yellow $(r.error)}")
                : render(colored, i"{red $(r.error)}");
            string[] errCols = [r.name, r.reps.to!string, message];
            while (errCols.length < headers.length)
                errCols ~= "—";
            cells ~= errCols;
            continue;
        }

        string[] cols = [
            r.name,
            r.reps.to!string,
            durCell(double(r.wall.wallNs)),
            durCell(r.wall.onCpuUserNs),
            durCell(r.wall.onCpuKernelNs),
            durCell(r.wall.offCpuRunqueueNs),
            durCell(r.wall.offCpuOtherNs),
        ];
        if (hasPsi)
            cols ~= r.psi.isNull ? "—" : durCell(r.psi.get.ioSomeNs);
        if (hasPerf)
        {
            if (r.perf.isNull)
                cols ~= ["—", "—", "—", "—"];
            else
            {
                const p = r.perf.get;
                const mark = isEstimatedScale(p.scale) && !p.instructions.isNaN
                    ? "≈" : "";
                static string est(string mark, double v) @safe
                    => v.isNaN ? "—" : mark ~ scaled(v);
                cols ~= [
                    est(mark, p.instructions),
                    est(mark, p.cycles),
                    p.ipc.isNaN ? "—" : mark ~ fixedRatio(p.ipc),
                    est(mark, p.pageFaults),
                ];
            }
        }
        if (hasTier0)
        {
            if (r.tier0.isNull)
                cols ~= ["—", "—", "—"];
            else
            {
                const t = r.tier0.get;
                cols ~= [scaled(t.majflt), scaled(t.rdBytes), scaled(t.wrBytes)];
            }
        }
        if (hasSyscalls)
        {
            if (r.syscalls.isNull)
                foreach (_; 0 .. 1 + syscallNames.length)
                    cols ~= "—";
            else
            {
                const s = r.syscalls.get;
                const mark = isEstimatedScale(s.scale) && !s.total.isNaN ? "≈" : "";
                cols ~= s.total.isNaN ? "—" : mark ~ scaled(s.total);
                foreach (i; 0 .. syscallNames.length)
                    cols ~= i < s.counts.length && !s.counts[i].isNaN
                        ? mark ~ scaled(s.counts[i]) : "—";
            }
        }
        if (hasRaw)
        {
            if (r.raw.isNull)
                foreach (_; 0 .. rawSelectors.length)
                    cols ~= "—";
            else
            {
                const w = r.raw.get;
                const mark = isEstimatedScale(w.scale) ? "≈" : "";
                foreach (i; 0 .. rawSelectors.length)
                    cols ~= i < w.values.length && !w.values[i].isNaN
                        ? mark ~ scaled(w.values[i]) : "—";
            }
        }
        if (hasNote)
            cols ~= r.wall.note.length
                ? render(colored, i"{dim $(r.wall.note)}") : "";
        cells ~= cols;
    }

    return BenchTableModel(render(colored, i"{bold workloads}"), cells, aligns);
}

/// A ratio with two decimals for the workload table (`ipc`); the caller
/// handles nan.
private string fixedRatio(double v) @safe
{
    import std.format : format;

    return format!"%.2f"(v);
}

@("reporting.buildWorkloadTable.columnsAndDashes")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.typecons : nullable;
    import sparkles.test_runner.perf : PerfStats;

    WorkloadWindow plain;
    plain.name = "ingest";
    plain.reps = 2;
    plain.wall.wallNs = 40_000_000;
    plain.wall.onCpuUserNs = 30_000_000;
    plain.wall.onCpuKernelNs = 4_000_000;
    plain.wall.offCpuOtherNs = 6_000_000; // runqueue stays nan
    plain.wall.note = "runqueue wait unattributed (schedstat unreadable) — included in other";

    WorkloadWindow perfy;
    perfy.name = "crunch";
    perfy.reps = 1;
    perfy.wall.wallNs = 10_000_000;
    perfy.wall.onCpuUserNs = 9_000_000;
    perfy.wall.onCpuKernelNs = 0;
    perfy.wall.offCpuOtherNs = 1_000_000;
    PerfStats p;
    p.iters = 1;
    p.cycles = 3.1e9;
    p.instructions = 2.4e9;
    p.pageFaults = 12;
    perfy.perf = nullable(p);

    const model = buildWorkloadTable([plain, perfy], false);
    assert(model.cells[0][0 .. 7] == ["workload", "reps", "wall", "cpu usr",
            "cpu krn", "runq", "other"]);
    assert(model.cells[0].canFind("instr"));
    assert(model.cells[0].canFind("note"));
    assert(!model.cells[0].canFind("maj-flt"), "no tier-0 row → no tier-0 columns");
    assert(!model.cells[0].canFind("io-stall"), "no psi row → no io-stall column");

    const r1 = model.cells[1];
    assert(r1[0] == "ingest" && r1[1] == "2");
    assert(r1[5] == "—", "an unattributable component is an em dash, never 0");
    assert(r1[7] == "—", "no perf on this row");
    assert(r1[$ - 1].canFind("runqueue"), "the disclosure rides the note column");

    const r2 = model.cells[2];
    assert(r2[7] == "2.40G", "window totals render SI-scaled");
    assert(r2[9] == "0.77", "ipc over the window's totals");
    assert(r2[$ - 1] == "", "no note on a clean window");
}

@("reporting.buildWorkloadTable.estimatesAndErrors")
@system
unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import std.typecons : nullable;
    import sparkles.test_runner.perf : PerfStats;

    WorkloadWindow scaledWin;
    scaledWin.name = "multiplexed";
    scaledWin.reps = 1;
    scaledWin.wall.wallNs = 5_000_000;
    PerfStats p;
    p.iters = 1;
    p.instructions = 1e9;
    p.cycles = 2e9;
    p.scale = 0.5; // multiplexed ≥ 1 ms: labeled estimate
    scaledWin.perf = nullable(p);

    WorkloadWindow err;
    err.name = "bad";
    err.reps = 1;
    err.error = "object.Exception: boom";

    WorkloadWindow skipped;
    skipped.name = "skippy";
    skipped.reps = 1;
    skipped.error = "no hardware";
    skipped.skipped = true;

    const model = buildWorkloadTable([scaledWin, err, skipped], false);
    assert(model.cells[1][7].startsWith("≈"), "a scaled window is a labeled estimate");
    assert(model.cells[2][2] == "object.Exception: boom");
    assert(model.cells[2][3] == "—", "error rows pad with em dashes");
    assert(model.cells[3][2] == "no hardware");

    const rendered = formatWorkloadTable([scaledWin], false);
    assert(rendered.canFind("workloads"), "the table carries its title");
}

@("reporting.buildWorkloadTable.ioStallColumn")
@system
unittest
{
    import std.algorithm.searching : countUntil;
    import std.typecons : nullable;
    import sparkles.test_runner.perf : PerfStats;
    import sparkles.test_runner.workload : PsiStats;

    WorkloadWindow withPsi;
    withPsi.name = "io-y";
    withPsi.reps = 1;
    withPsi.wall.wallNs = 30_000_000;
    withPsi.wall.onCpuUserNs = 5_000_000;
    withPsi.wall.offCpuOtherNs = 25_000_000;
    PsiStats p;
    p.ioSomeNs = 21_900_000;
    withPsi.psi = nullable(p);
    PerfStats pf;
    pf.iters = 1;
    pf.instructions = 1e6;
    pf.cycles = 2e6;
    withPsi.perf = nullable(pf);

    WorkloadWindow noPsi;
    noPsi.name = "plain";
    noPsi.reps = 1;
    noPsi.wall.wallNs = 1_000_000;

    const model = buildWorkloadTable([withPsi, noPsi], false);
    const header = model.cells[0];
    // Placement is the contract: after `other` (context, not a
    // decomposition part), before the perf block.
    assert(header.countUntil("io-stall") == header.countUntil("other") + 1);
    assert(header.countUntil("io-stall") < header.countUntil("instr"));
    assert(model.cells[1][header.countUntil("io-stall")] == "21.9ms");
    assert(model.cells[2][header.countUntil("io-stall")] == "—",
        "a psi-less row in a psi table reads an em dash");

    // All-nan psi values (io reads failed after the probe) suppress the
    // column entirely — never an all-em-dash column.
    WorkloadWindow nanPsi;
    nanPsi.name = "nan";
    nanPsi.reps = 1;
    nanPsi.wall.wallNs = 1;
    nanPsi.psi = nullable(PsiStats.init);
    import std.algorithm.searching : canFind;

    assert(!buildWorkloadTable([nanPsi], false).cells[0].canFind("io-stall"));
}

/// Per-column visible content widths over a table's rows, header included
/// (ANSI escapes cost zero cells).
private size_t[] contentWidths(in string[][] cells) @safe
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
    return widths;
}

/// Element-wise maximum of two width vectors (result spans the longer one).
private size_t[] mergeWidths(in size_t[] a, in size_t[] b) @safe
{
    import std.algorithm.comparison : max;

    auto merged = new size_t[max(a.length, b.length)];
    foreach (i, ref w; merged)
        w = max(i < a.length ? a[i] : 0, i < b.length ? b[i] : 0);
    return merged;
}

/// One live frame of a group's results table (the `--bench` ticker): the rows
/// measured so far — sorted exactly like the final table — plus, while
/// `inflight.name` is set, a dim `⠹ name │ measuring… │` row pinned to the
/// bottom. The frame renders through the same model, alignment, title, and
/// `geometry` floors as the flushed table (which `nameFloor`, the group
/// roster's widest spinner-prefixed name, extends), so frames never resize as
/// rows land and the last frame is line-identical to the graduated table.
/// Returns table lines without trailing newlines (for `LiveRegion.update`);
/// `null` when there is nothing to show or without `core-cli`.
package string[] benchFrameLines(in BenchStats[] rows, BenchStats inflight,
    size_t spin, bool colored, string metricFilter, string sortBy,
    in string[] groupKeys, size_t nameFloor, ref TableGeometry geometry) @system
{
    static if (hasUiComponents)
    {
        import std.algorithm.searching : canFind;
        import std.array : array;
        import sparkles.ui.components.progress : spinnerFrame;
        import sparkles.ui.components.table : drawTableLines, TableProps;
        import sparkles.test_runner.metrics : labelKeyUnion;

        if (rows.length == 0 && inflight.name.length == 0)
            return null;

        // The in-flight case rides through the model as a pseudo error row —
        // that yields the group's title/header/columns even before the first
        // real row lands, and error rows sort last, pinning it to the bottom.
        // The sentinel marks it for the rewrite below (its rendered cells are
        // replaced wholesale); the notes-column gate in `buildBenchTables`
        // excludes it, so a green group never grows a notes column mid-run.
        enum sentinel = benchInflightSentinel;
        const(BenchStats)[] allRows = inflight.name.length
            ? rows ~ BenchStats(name: inflight.name, labels: inflight.labels,
                error: sentinel)
            : rows;

        auto models = buildBenchTables(allRows, colored, metricFilter, sortBy,
            groupKeys);
        assert(models.length == 1, "a frame renders exactly one group");
        auto model = models[0];

        // Column of the case name (the spinner stub) and of median/iter (the
        // `measuring…` cell) — mirroring buildBenchTables' layouts: grouped is
        // `[name] restKeys… iters median …`, flat is `labelKeys… name iters
        // median …`.
        size_t nameIdx, medianIdx;
        if (groupKeys.length)
        {
            size_t restCount;
            foreach (key; labelKeyUnion(allRows))
                if (!groupKeys.canFind(key))
                    restCount++;
            nameIdx = 0;
            medianIdx = 1 + restCount + 1;
        }
        else
        {
            nameIdx = labelKeyUnion(allRows).length;
            medianIdx = nameIdx + 2;
        }

        foreach (ref row; model.cells[1 .. $])
        {
            if (!row.canFind!(c => c.canFind(sentinel)))
                continue;
            const glyph = spinnerFrame(spin);
            const name = inflight.name;
            row[nameIdx] = render(colored, i"{dim $(glyph) $(name)}");
            foreach (i; medianIdx - 1 .. row.length) // the `n` column onward
                row[i] = "";
            // `measuring…` rides in the right-aligned `n` column, NOT the
            // decimal median one: a dotless cell in a decimal column gets a
            // layout-internal trailing pad the geometry floors cannot carry,
            // so the column would shrink when the row lands (the sentinel is
            // parked in the `n` cell for the same reason).
            row[medianIdx - 1] = render(colored, i"{dim measuring…}");
            break;
        }

        auto floors = applyGeometry(&geometry, models);
        if (nameIdx < floors.length && floors[nameIdx] < nameFloor)
        {
            floors[nameIdx] = nameFloor;
            geometry.floors = mergeWidths(geometry.floors, floors);
        }

        return drawTableLines(model.cells, TableProps(
            headerRows: 1, title: model.title, columnAligns: model.aligns.dup,
            columnMinWidths: floors.dup, columnMaxWidths: model.maxWidths.dup)).array;
    }
    else
    {
        return null; // the ticker is gated on core-cli in the runner
    }
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

/// `median/iter` folds the deviation into one right-aligned cell
/// (`30.00ns ±1.00ns`); the standalone `±dev` column is gone, while `min` and
/// `max` remain their own decimal-aligned columns.
@("formatBenchTable.mergedMedianColumn")
@system
unittest
{
    import std.algorithm.searching : canFind;

    BenchStats[1] rows = [
        BenchStats(name: "fast", samples: 100, iterations: 1,
            nsPerIterMedian: 110, nsPerIterDeviation: 5,
            nsPerIterMin: 108, nsPerIterMax: 120),
    ];
    const rendered = formatBenchTable(rows[], false);

    // The median and its deviation share one cell; the dedicated ±dev column
    // and its header are gone; min/max keep their own cells.
    assert(rendered.canFind("110.00ns ±5.00ns"), rendered);
    assert(!rendered.canFind("±dev"), rendered);
    assert(rendered.canFind("min") && rendered.canFind("max"), rendered);
    assert(rendered.canFind("108.00ns") && rendered.canFind("120.00ns"), rendered);
}

/// The `n` column shows the sample count (what `--bench-min-time` grows); a
/// batched case running several iterations per sample reads `samples×iters`.
@("formatBenchTable.sampleCountColumn")
@system
unittest
{
    import std.algorithm.searching : canFind;

    BenchStats[1] perCall = [BenchStats(name: "a", samples: 19000, iterations: 1,
        nsPerIterMedian: 30)];
    assert(formatBenchTable(perCall[], false).canFind("19000"), "per-call: n = samples");

    BenchStats[1] batched = [BenchStats(name: "a", samples: 32, iterations: 8,
        nsPerIterMedian: 30)];
    assert(formatBenchTable(batched[], false).canFind("32×8"), "batched: samples×iterations");
}

/// A failing row's message rides in a trailing, wrapping `notes` column — never
/// in a timing cell; a passing row's note is empty, and an all-green table grows
/// no notes column at all.
@("formatBenchTable.notesColumn")
@system
unittest
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;

    BenchStats[2] rows = [
        BenchStats(name: "ok", samples: 100, iterations: 1, nsPerIterMedian: 30),
        BenchStats(name: "bad", error: "boom: it failed"),
    ];
    const rendered = formatBenchTable(rows[], false);
    assert(rendered.canFind("notes"), rendered);          // header present
    assert(rendered.canFind("boom: it failed"), rendered); // message in the table
    assert(rendered.canFind("30.00ns ±0.00ns"), rendered); // passing row keeps timings

    // No error rows → no notes column (legacy layout preserved).
    BenchStats[1] green = [BenchStats(name: "ok", samples: 100, iterations: 1,
        nsPerIterMedian: 30)];
    assert(!formatBenchTable(green[], false).canFind("notes"), "no notes header when green");

    // A long message wraps within the cap on the drawTable path: the words all
    // survive, but the full line is broken across rows (never contiguous).
    static if (hasUiComponents)
    {
        enum long_ = "serialize output is not valid JSON: Illegal control "
            ~ "character somewhere deep inside the payload buffer";
        BenchStats[1] longErr = [BenchStats(name: "bad", error: long_)];
        const wrapped = formatBenchTable(longErr[], false);
        assert(wrapped.canFind("serialize") && wrapped.canFind("payload"), wrapped);
        assert(!wrapped.canFind(long_), "a long note must wrap, not stay one line");
    }
}

/// A `TableGeometry` threaded across calls keeps consecutive streamed tables
/// on one column layout: the second (narrower) table renders under the first
/// call's floors, so their lines share a visible width — instead of the
/// naturally narrower layout it gets alone.
@("formatBenchTable.geometryCarriesAcrossCalls")
@system
unittest
{
    import std.string : splitLines;

    // `wide` must dominate every value column (name, n, merged median, min,
    // max) so the carried floors equal its own widths and the narrower second
    // table renders under them. Sub-µs medians format widest, so a nonzero
    // deviation keeps the wide median cell the longest.
    TableGeometry geom;
    BenchStats[1] wide = [BenchStats(name: "a-rather-long-benchmark-name",
        samples: 19000, iterations: 1, nsPerIterMedian: 110,
        nsPerIterDeviation: 99, nsPerIterMin: 108, nsPerIterMax: 120)];
    BenchStats[1] narrow = [BenchStats(name: "b", samples: 1, iterations: 1,
        nsPerIterMedian: 30)];

    const first = formatBenchTable(wide[], false, null, null, null, &geom);
    const second = formatBenchTable(narrow[], false, null, null, null, &geom);
    assert(visibleWidth(first.splitLines[0]) == visibleWidth(second.splitLines[0]),
        first ~ second);

    const alone = formatBenchTable(narrow[], false);
    assert(visibleWidth(alone.splitLines[0]) < visibleWidth(second.splitLines[0]));
}

/// A table with a different column set (here: an extra metric column) resets
/// the carried floors instead of misapplying them positionally — the output
/// matches a fresh render exactly.
/// A ticker frame carries the group's title, the measured rows, and a dim
/// spinner row for the in-flight case — with `measuring…` in the timing
/// column and its real label values in the rest columns — even before any row
/// has landed (the pseudo row alone yields the table skeleton).
@("reporting.benchFrameLines.inflightRow")
@system
unittest
{
    static if (hasUiComponents)
    {
        import std.algorithm.searching : canFind;
        import std.array : join;

        TableGeometry geom;
        BenchStats[1] rows = [BenchStats(name: "asdf",
            labels: ["dataset": "canada"], iterations: 1, nsPerIterMedian: 30)];
        auto inflight = BenchStats(name: "mir-ion", labels: ["dataset": "canada"]);

        const frame = benchFrameLines(rows[], inflight, 0, false, null, null,
            ["dataset"], 0, geom);
        assert(frame.canFind!(l => l.canFind("benchmark: canada")), frame.join("\n"));
        assert(frame.canFind!(l => l.canFind("asdf")));
        assert(frame.canFind!(l => l.canFind("⠋ mir-ion")));
        assert(frame.canFind!(l => l.canFind("measuring…")));
        assert(!frame.canFind!(l => l.canFind("\x01")), "sentinel must not leak");

        // No rows landed yet: the skeleton (title + header + spinner row) shows.
        TableGeometry fresh;
        const first = benchFrameLines(null, inflight, 2, false, null, null,
            ["dataset"], 0, fresh);
        assert(first.canFind!(l => l.canFind("benchmark: canada")));
        assert(first.canFind!(l => l.canFind("⠹ mir-ion")));
    }
}

/// The last frame of a group (no in-flight row) is line-identical to the
/// table the piped path flushes — graduation swaps nothing visually.
@("reporting.benchFrameLines.finalFrameMatchesFlushedTable")
@system
unittest
{
    static if (hasUiComponents)
    {
        import std.array : join;

        BenchStats[2] rows = [
            BenchStats(name: "asdf", labels: ["dataset": "canada"],
                iterations: 1, nsPerIterMedian: 30),
            BenchStats(name: "mir-ion", labels: ["dataset": "canada"],
                iterations: 1, nsPerIterMedian: 10),
        ];

        TableGeometry frameGeom, flushGeom;
        const frame = benchFrameLines(rows[], BenchStats.init, 0, false, null,
            null, ["dataset"], 0, frameGeom);
        const flushed = formatBenchTable(rows[], false, null, null, ["dataset"],
            &flushGeom);
        assert(frame.join("\n") ~ "\n" == flushed, frame.join("\n"));
        assert(frameGeom == flushGeom);
    }
}

@("formatBenchTable.geometryResetsOnHeaderChange")
@system
unittest
{
    import sparkles.test_runner.bench : Metric, Unit;

    TableGeometry geom;
    BenchStats[1] plain = [BenchStats(name: "a-rather-long-benchmark-name",
        iterations: 1, nsPerIterMedian: 110)];
    cast(void) formatBenchTable(plain[], false, null, null, null, &geom);

    BenchStats[1] withMetric = [BenchStats(name: "b", iterations: 1,
        nsPerIterMedian: 110, metrics: [Metric(Unit("B"), 1000.0, Metric.Mode.rate)])];
    assert(formatBenchTable(withMetric[], false, null, null, null, &geom)
        == formatBenchTable(withMetric[], false));
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

    // --group-by=dataset,operation → one table per group; the group name rides
    // in the table title, `implementation` heads the stub column, and rows
    // list the engine `name`.
    const rendered = formatBenchTable(rows, false, null, null, ["dataset", "operation"]);
    assert(rendered.canFind("benchmark: canada/parse"));
    assert(rendered.canFind("benchmark: twitter/parse"));
    assert(rendered.canFind("implementation"));
    assert(!rendered.canFind("implementation:"), "plain header cell, no label colon");
    assert(rendered.canFind("mir-ion"));
    // Two tables → two titled top borders (heading lines in the fallback).
    assert(rendered.indexOf("benchmark:")
        != rendered.indexOf("benchmark:", rendered.indexOf("benchmark:") + 1));
    // Within the canada group, the faster engine (mir-ion, 10) precedes asdf (30).
    assert(rendered.indexOf("mir-ion") < rendered.indexOf("asdf"));
}

@("formatBenchTable.groupedKeepsRemainingLabels")
@system
unittest
{
    import std.algorithm.searching : canFind;

    // Label keys NOT in --group-by still discriminate rows: grouping only by
    // dataset must keep an `operation` column, or three identically-named
    // engine rows (parse/serialize/validate) are indistinguishable.
    static BenchStats row(string engine, string operation)
    {
        return BenchStats(name: engine,
            labels: ["dataset": "canada", "operation": operation], iterations: 1,
            nsPerIterMedian: 10);
    }

    BenchStats[2] rows = [row("asdf", "parse"), row("asdf", "serialize")];
    const rendered = formatBenchTable(rows, false, null, null, ["dataset"]);
    assert(rendered.canFind("operation"), "the non-grouped label key gets a column");
    assert(rendered.canFind("parse") && rendered.canFind("serialize"));
    assert(!rendered.canFind("dataset"), "the grouped key lives in the title only");

    // Cases with none of the grouped labels title as (unlabeled), not `/`.
    BenchStats bare;
    bare.name = "plain";
    bare.iterations = 1;
    const bareTable = formatBenchTable([bare], false, null, null, ["dataset"]);
    assert(bareTable.canFind("benchmark: (unlabeled)"));
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

/// The `--list-metrics` capability block: what each backend can deliver on
/// this host, this run — one `✓ capability` / `✗ capability — reason` line
/// per flag a backend claims or explains, grouped by backend, flags in
/// declaration order. Reasons are prose, so the block is plain indented lines
/// rather than a table.
string formatCapabilityBlock(in BackendCapabilities[] blocks, bool colored) @safe
{
    import std.algorithm.comparison : max;
    import std.string : leftJustify;

    size_t labelWidth = 0;
    foreach (ref b; blocks)
        labelWidth = max(labelWidth, b.backend.length);

    string o = render(colored, i"{bold capabilities}") ~ ":\n";
    foreach (ref b; blocks)
    {
        bool first = true;
        foreach (flag; allCapabilities)
        {
            string line;
            if (b.report.has(flag))
                line = render(colored, i"{green ✓} $(capabilityName(flag))");
            else
            {
                const reason = b.report.reasonFor(flag);
                if (reason is null)
                    continue;
                line = render(colored, i"{red ✗} $(capabilityName(flag)) — $(reason)");
            }
            o ~= "  " ~ leftJustify(first ? b.backend : "", labelWidth + 1)
                ~ line ~ "\n";
            first = false;
        }
    }
    return o;
}

@("reporting.formatCapabilityBlock.plain")
@safe
unittest
{
    import sparkles.test_runner.capability : Capability, CapabilityAbsence,
        CapabilityReport;

    static immutable CapabilityAbsence[1] tracing = [
        CapabilityAbsence(Capability.eventTracing, "tracefs event ids unreadable — usually root"),
    ];
    const blocks = [
        BackendCapabilities("perf", CapabilityReport(Capability.counting, null)),
        BackendCapabilities("syscall", CapabilityReport(Capability.none, tracing[])),
    ];
    assert(formatCapabilityBlock(blocks, false) ==
        "capabilities:\n"
        ~ "  perf    ✓ counting\n"
        ~ "  syscall ✗ eventTracing — tracefs event ids unreadable — usually root\n");
}

@("reporting.formatCapabilityBlock.colored")
@safe
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.test_runner.capability : Capability, CapabilityReport;

    const blocks = [
        BackendCapabilities("perf", CapabilityReport(Capability.counting, null)),
    ];
    const colored = formatCapabilityBlock(blocks, true);
    assert(colored.canFind("✓") && colored.canFind("\x1b["));
}

/// Renders table cells with `core-cli`'s `drawTable` when available, plain
/// space-aligned columns otherwise. `aligns`/`headerRows` describe per-column
/// alignment and the header-rule row count; `Align` lives in `base`, so this
/// signature stays valid without `core-cli` (`TableProps` is built strictly
/// inside the capability gate), and the fallback honors right/decimal columns
/// as plain right alignment. `title` (may be styled) is spliced into the top
/// border — `╭──╼ benchmark: canada ╾──╮` — or, with no border to interrupt,
/// hoisted as a heading line above the plain fallback. `minWidths` floors the
/// column content widths (`TableProps.columnMinWidths`; honored by the
/// fallback too), letting consecutive streamed tables share their geometry.
/// `maxWidths` caps them (`TableProps.columnMaxWidths`; content over a column's
/// cap wraps on the `drawTable` path, ignored by the plain fallback).
package string renderCells(
    string[][] cells, in Align[] aligns = null, size_t headerRows = 0,
    string title = null, in size_t[] minWidths = null, in size_t[] maxWidths = null)
@system // drawTable is @system
{
    static if (hasUiComponents)
    {
        import sparkles.ui.components.table : drawTable, TableProps;

        return drawTable(cells, TableProps(
            headerRows: headerRows, columnAligns: aligns.dup, title: title,
            columnMinWidths: minWidths.dup, columnMaxWidths: maxWidths.dup));
    }
    else
    {
        // The plain fallback has no wrapping engine, so `maxWidths` is ignored;
        // `errorCell` already collapses a message to one line for this grid.
        auto table = alignColumns(cells, aligns, minWidths);
        return title.length ? title ~ "\n" ~ table : table;
    }
}

/// Both renderings surface a `title`: the gated build splices it into the top
/// border (given a rule wide enough to carry the label — bench tables always
/// are); the fallback hoists it as a heading line. Either way it precedes the
/// cells, so this pins the property common to both builds.
@("reporting.renderCells.titled")
@system
unittest
{
    import std.string : indexOf;

    const rendered = renderCells([["one sufficiently wide header"], ["v"]], null,
        headerRows: 1, title: "benchmark: canada");
    assert(rendered.indexOf("benchmark: canada") >= 0, rendered);
    assert(rendered.indexOf("benchmark: canada") < rendered.indexOf("v"), rendered);
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
/// emoji / combining clusters are sized correctly (matching `drawTable`), and
/// `minWidths` floors them (matching `TableProps.columnMinWidths`).
package string alignColumns(in string[][] cells, in Align[] aligns = null,
    in size_t[] minWidths = null) @safe
{
    auto widths = mergeWidths(contentWidths(cells), minWidths);

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

/// `minWidths` floors widen a column past its natural width (the gap after a
/// left column grows; a right column pads further); short/absent entries
/// leave columns natural — mirroring `TableProps.columnMinWidths`.
@("alignColumns.minWidthFloors")
@safe
unittest
{
    assert(alignColumns([["a", "b"], ["c", "d"]], null, [3]) ==
        "a    b\n" ~
        "c    d\n");
    assert(alignColumns([["a", "22"], ["ccc", "4"]],
            [Align.left, Align.right], [0, 4]) ==
        "a      22\n" ~
        "ccc     4\n");
}

// ─────────────────────────────────────────────────────────────────────────────
// Live progress (the bench spinner on stderr, the parallel run on stdout)
// ─────────────────────────────────────────────────────────────────────────────

/// The one policy for whether a live, redraw-in-place progress display may
/// animate on a stream: it must be an interactive terminal, colors must not
/// be disabled (`--no-colors` / `$NO_COLOR`), and the terminal must not be
/// `TERM=dumb` (no cursor-control escapes). The bench spinner asks about
/// stderr (the default — results piped to a file still show progress on the
/// terminal); the parallel-run progress line asks about stdout, where it
/// interleaves with the streamed result lines.
package bool progressEnabled(bool noColors, bool stderrStream = true)
{
    import std.process : environment;

    if (noColors || environment.get("NO_COLOR", "").length != 0
        || environment.get("TERM", "") == "dumb")
        return false;
    static if (hasTermCaps)
    {
        import sparkles.base.term_caps : isTerminal, StdStream;

        return isTerminal(stderrStream ? StdStream.stderr : StdStream.stdout);
    }
    else
    {
        version (Posix)
        {
            import core.sys.posix.unistd : isatty, STDERR_FILENO, STDOUT_FILENO;

            return isatty(stderrStream ? STDERR_FILENO : STDOUT_FILENO) != 0;
        }
        else
            return false;
    }
}

/// Raw, unbuffered write to stderr's fd — `@nogc nothrow` (unlike
/// `std.stdio.stderr.write`), so it is callable from the `@safe nothrow @nogc`
/// progress hook. No-op on non-POSIX.
private void writeStderr(scope const(char)[] s) @safe nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : write, STDERR_FILENO;

        if (s.length)
            // Minimal @trusted: the ptr+length pair handed to the syscall
            // comes from one slice, so the unsafe surface is just the call.
            cast(void) (() @trusted => write(STDERR_FILENO, s.ptr, s.length))();
    }
}

/// `s` truncated to at most `maxCells` display columns, measured in true
/// terminal cells via grapheme clustering (wide CJK/emoji count 2, combining
/// marks 0) — a code-point approximation lets a wide-glyph case name overflow
/// the terminal, wrap, and leave a ghost row the one-line CR+erase can't
/// clear. Never splits a cluster.
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
    bool active;             /// stderr is an interactive tty (colors on)
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

        static if (hasUiComponents)
        {
            import sparkles.base.smallbuffer : SmallBuffer;
            import sparkles.base.term_control : CtlSeq;
            import sparkles.base.text.width : truncateField;
            import sparkles.ui.components.progress : ProgressLine;

            if (started == MonoTime.init)
                started = MonoTime.currTime;
            const shown = done > total ? done : total; // never render done > total
            const elapsed = MonoTime.currTime - started;

            // Measure the (uncolored) prefix so the label gets the terminal's
            // remaining columns; truncate it there rather than to a fixed 80
            // that wraps a narrow terminal and leaves a ghost row the
            // CR+eraseLine (one physical line) can't erase. width==0
            // (unknown/piped) keeps the old fixed cap, so nothing changes there.
            SmallBuffer!(char, 64) plainPrefix;
            ProgressLine(frame, done, shown, false, elapsed).toString(plainPrefix);
            const prefixCells = visibleWidth(plainPrefix[]);
            const budget = width == 0
                ? 80
                : (width > prefixCells + 1 ? width - prefixCells - 1 : 0);

            // The erase+redraw is bracketed in DEC-2026 synchronized output
            // (the same trick as core-cli's LiveRegion), so a repaint lands as
            // one frame — no flicker mid-erase. Unsupporting terminals ignore
            // the private mode.
            SmallBuffer!(char, 256) buf;
            buf ~= cast(string) CtlSeq.syncBegin;
            buf ~= cast(string) CtlSeq.carriageReturn;
            buf ~= cast(string) CtlSeq.eraseLine;
            ProgressLine(frame, done, shown, true, elapsed).toString(buf);
            if (budget > 0)
            {
                buf ~= ' ';
                // base's truncateField: cell-measured, never splits a cluster,
                // `…`-marks an overlong case name (attributes infer, so the
                // SmallBuffer keeps this seam `@safe nothrow @nogc`).
                buf.truncateField(name, budget);
            }
            buf ~= cast(string) CtlSeq.syncEnd;
            writeStderr(buf[]);
        }
    }

    /// Erase the spinner line (before printing a table, and at the end).
    /// `CtlSeq` lives in `base`, so unlike `tick` (which needs `core-cli`'s
    /// `ProgressLine`) this needs no capability gate.
    void clear() @safe nothrow @nogc
    {
        import sparkles.base.term_control : CtlSeq;

        if (!active)
            return;
        enum eraseSeq = cast(string) CtlSeq.syncBegin
            ~ cast(string) CtlSeq.carriageReturn
            ~ cast(string) CtlSeq.eraseLine
            ~ cast(string) CtlSeq.syncEnd;
        writeStderr(eraseSeq);
    }
}
