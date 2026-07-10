#!/usr/bin/env dub
/+ dub.sdl:
name "streaming-table"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
+/

module streaming_table_example;

// Animated `drawTable`: table layout is eager (column widths must scan all
// content), but emission is lazy — `drawTableChunks` yields the rendered table
// as a range of chunks, so pacing the iteration reveals the table piece by
// piece while the frame (borders, the heavy header rule, the spliced title and
// footer) rides along on the neighbouring content chunks.
//
// `--mode` picks the chunk granularity:
//
//   * cell (default)  `drawTableChunks!false` — one chunk per contentful cell
//                     field, revealed in reading order like a spreadsheet
//                     filling itself in
//   * line            `drawTableChunks!true` — one chunk per rendered line,
//                     like a classic query-result printer
//
// The rows come from one of two sources:
//
//   * generated (default) — a styled fleet-status board: ANSI-styled statuses,
//     CJK + emoji regions, a decimal-aligned latency column, a colspan summary
//     row
//   * shell command       --command 'cmd' — each stdout line splits on
//     whitespace runs into columns (--columns N folds everything from field N
//     onward into the last column, e.g. `--command 'ps aux' --columns 11`);
//     the first line becomes the header row
//
// `--pace width` makes each pause proportional to the visible width the next
// chunk reveals (constant columns/second, so wide CJK cells take longer),
// instead of the default fixed delay per chunk.
//
//   dub run --single streaming-table.d
//   dub run --single streaming-table.d -- --mode line --delay 120
//   dub run --single streaming-table.d -- --preset heavy --rows 12
//   dub run --single streaming-table.d -- --pace width --delay 30
//   dub run --single streaming-table.d -- --tee /tmp/fleet.txt --delay 0
//   dub run --single streaming-table.d -- --command 'df -h' --max-width 100
//   dub run --single streaming-table.d -- --command 'ps aux' --columns 11 --max-width 120

import core.thread : Thread;
import core.time : dur;
import std.range.primitives : ElementType, empty, front, popFront;
import std.stdio : stderr, stdout, write;

import sparkles.core_cli.args;
import sparkles.core_cli.ui.table :
    builtinPresetNames, Cell, drawTable, drawTableChunks, presetGlyphs, TableProps;
import sparkles.base.styled_template : styledText;
import sparkles.base.text.grapheme : visibleWidth;
import sparkles.base.text.width : Align;

/// Default number of generated data rows.
enum int fleetDefaultRows = 8;

struct CliParams
{
    // Note: descriptions must avoid double quotes — parseCliArgs pastes them
    // into generated mixin code verbatim.
    @CliOption("m|mode", "Chunk granularity: cell (one chunk per cell field) or line")
    string mode = "cell";

    @CliOption("d|delay", "Animation delay per streamed chunk, in milliseconds")
    int delayMs = 45;

    @CliOption("pace", "Chunk pacing: fixed (delay ms per chunk) or width (delay ms per 10 visible columns)")
    string pace = "fixed";

    @CliOption("p|preset", "Glyph preset: rounded, square, ascii, double, heavy")
    string preset = "rounded";

    @CliOption("w|max-width", "Cap the table width in columns, 0 = expand to fit")
    int maxWidth = 0;

    @CliOption("r|rows", "Number of generated data rows (generated source only)")
    int rows = fleetDefaultRows;

    @CliOption("command", "Run this shell command; its stdout lines become the rows")
    string command;

    @CliOption("c|columns", "Fold command output into at most this many columns, 0 = one per whitespace run")
    int columns = 0;

    @CliOption("tee", "Also write the table to this file via the writer drawTable overload and check byte parity with the streamed output")
    string tee;
}

/// A range that sleeps on each `popFront`, so consuming it animates output.
/// The delay is a function of the chunk *about to appear*, so pacing can be
/// uniform (a fixed pause per chunk) or proportional to how much text the next
/// chunk reveals (as if it were being typed).
struct DelayedRange(R)
{
    private R _src;
    private int delegate(ElementType!R) _delayFor;

    bool empty() => _src.empty;
    ElementType!R front() => _src.front;
    void popFront()
    {
        _src.popFront;
        if (!_src.empty)
            Thread.sleep(dur!"msecs"(_delayFor(_src.front)));
    }
}

// The delegate type is its own template parameter: IFTI cannot deduce `R`
// through `ElementType!R` in a parameter position.
auto delayedRange(R, F)(R src, F delayFor) => DelayedRange!R(src, delayFor);

/// A demo table: the cells plus the props describing them (title, footer, header
/// rule, per-column alignment). The CLI's glyph preset and width cap are merged
/// in afterwards.
struct DemoTable
{
    Cell[][] cells;
    TableProps props;
}

void main(string[] args)
{
    import core.stdc.stdlib : exit;
    import std.algorithm.searching : canFind;
    import std.array : join;

    const cli = args.parseCliArgs!CliParams(HelpInfo(
        "streaming-table",
        "Animated streaming drawTable demo (eager layout, lazy chunk emission)"));

    if (!["cell", "line"].canFind(cli.mode))
    {
        stderr.writeln(`streaming-table: --mode must be "cell" or "line", not "`,
            cli.mode, `"`);
        exit(2);
    }
    if (!builtinPresetNames.canFind(cli.preset))
    {
        stderr.writeln("streaming-table: unknown --preset '", cli.preset,
            "' (available: ", builtinPresetNames.join(", "), ")");
        exit(2);
    }
    if (!["fixed", "width"].canFind(cli.pace))
    {
        stderr.writeln(`streaming-table: --pace must be "fixed" or "width", not "`,
            cli.pace, `"`);
        exit(2);
    }

    // The pause before a chunk appears: constant, or proportional to the visible
    // width the chunk reveals (constant columns/second — wide CJK cells take
    // proportionally longer, exercising the grapheme-width machinery).
    const delayMs = cli.delayMs;
    int delegate(string) delayFor = (string chunk) => delayMs;
    if (cli.pace == "width")
        delayFor = (string chunk) => cast(int) (delayMs * visibleWidth(chunk) / 10);

    auto table = cli.command.length
        ? commandTable(cli.command, cli.columns)
        : generatedFleet(cli.rows);
    table.props.glyphs = presetGlyphs(cli.preset);
    table.props.maxWidth = cli.maxWidth;

    const streamed = cli.mode == "line"
        ? streamChunks(drawTableChunks!true(table.cells, table.props), delayFor)
        : streamChunks(drawTableChunks!false(table.cells, table.props), delayFor);

    if (cli.tee.length)
        teeAndCheck(cli.tee, table, streamed);
}

/// Write each chunk as it is produced; the delay between chunks is the animation.
/// No trailing newline needed — table chunks carry their own line terminators.
/// Returns the accumulated bytes (for the `--tee` parity check).
string streamChunks(R)(R chunks, int delegate(string) delayFor)
{
    import std.array : appender;

    auto seen = appender!string;
    foreach (chunk; chunks.delayedRange(delayFor))
    {
        write(chunk);
        stdout.flush(); // show each chunk as it is produced, not at program exit
        seen ~= chunk;
    }
    return seen[];
}

/// Write the same table through the writer `drawTable` overload into `path`, then
/// check the file against the bytes the chunk stream produced — the emission
/// seams (chunk range and output-range writer) must agree byte-for-byte.
void teeAndCheck(string path, DemoTable table, string streamed)
{
    import core.stdc.stdlib : exit;
    import std.file : readText;
    import std.stdio : File;

    {
        auto f = File(path, "w");
        auto w = f.lockingTextWriter;
        drawTable(w, table.cells, table.props);
    }
    const written = readText(path);
    if (written == streamed)
        stderr.writeln("streaming-table: tee: ", written.length, " bytes → ", path,
            " (byte-identical to the streamed output)");
    else
    {
        stderr.writeln("streaming-table: tee: PARITY MISMATCH — ", path,
            " differs from the streamed output");
        exit(1);
    }
}

/// The generated source: a fleet-status board exercising the layout features the
/// chunk stream must carry intact — ANSI-styled cells, CJK/emoji cell widths, a
/// heavy header rule, a decimal-aligned latency column, and a colspan summary row.
DemoTable generatedFleet(int rows)
{
    import std.conv : text;

    static immutable services =
        ["api", "web", "db", "cache", "queue", "auth", "search", "cdn"];
    static immutable regions =
        ["us-east-1", "eu-west-2", "日本 🇯🇵", "ap-south-1", "são-paulo"];
    static immutable latencies =
        ["12.4ms", "8.91ms", "102ms", "3.75ms", "56.2ms", "480ms", "7.125ms", "23.5ms"];

    enum Health { up, warn, down }
    static immutable Health[] healths = [
        Health.up, Health.up, Health.warn, Health.up,
        Health.down, Health.up, Health.warn, Health.up,
    ];

    static string statusLabel(Health h)
    {
        final switch (h)
        {
            case Health.up: return styledText(i"{green ✅ up}");
            case Health.warn: return styledText(i"{yellow ⚠ warn}");
            case Health.down: return styledText(i"{red ✗ down}");
        }
    }

    Cell[][] cells = [[
        Cell(styledText(i"{bold service}")),
        Cell(styledText(i"{bold region}")),
        Cell(styledText(i"{bold p99}")),
        Cell(styledText(i"{bold status}")),
    ]];
    int[3] counts;
    foreach (i; 0 .. rows)
    {
        // Cycle the sample data, uniquifying wrapped-around service names.
        const service = i < services.length
            ? services[i]
            : text(services[i % $], "-", i / services.length + 1);
        const health = healths[i % $];
        counts[health]++;
        cells ~= [
            Cell(service),
            Cell(regions[i % $]),
            Cell(latencies[i % $]),
            Cell(statusLabel(health)),
        ];
    }
    const summary = text(counts[Health.up], " up · ", counts[Health.warn],
        " warn · ", counts[Health.down], " down");
    cells ~= [Cell(styledText(i"{dim $(summary)}"), colSpan: 4, halign: Align.center)];

    return DemoTable(cells, TableProps(
        headerRows: 1,
        title: styledText(i"{bold Fleet status}"),
        footer: text(rows, " services"),
        columnAligns: [Align.left, Align.left, Align.decimal, Align.left],
    ));
}

/// The command source: run `cmd` in a shell and tabulate its stdout — each line
/// splits on whitespace runs; `maxColumns > 0` folds everything from field
/// `maxColumns - 1` onward into one last column (for `ps`-like output whose final
/// field contains spaces). The first line becomes the header row. Falls back to
/// the generated board when the command fails or prints nothing.
DemoTable commandTable(string cmd, int maxColumns)
{
    import std.algorithm.iteration : filter, map;
    import std.array : array, join, split;
    import std.conv : text;
    import std.string : strip;

    auto lines = runShell(cmd).filter!(l => l.strip.length).array;
    if (lines.length == 0)
        return generatedFleet(fleetDefaultRows);

    Cell[][] cells;
    foreach (line; lines)
    {
        auto fields = line.split; // split on whitespace runs
        if (maxColumns > 0 && fields.length > cast(size_t) maxColumns)
            fields = fields[0 .. maxColumns - 1] ~ fields[maxColumns - 1 .. $].join(" ");
        cells ~= fields.map!(f => Cell(f)).array; // ragged rows pad with blanks
    }
    return DemoTable(cells, TableProps(
        headerRows: 1,
        title: cmd,
        footer: text(cells.length - 1, " rows"),
    ));
}

/// Run a shell command and capture its stdout as lines (terminators stripped). On a
/// non-zero exit or a spawn failure, warn on stderr and return an empty array so the
/// caller can fall back to generated output.
string[] runShell(string cmd)
{
    import std.process : pipeShell, ProcessException, Redirect, wait;

    try
    {
        auto p = pipeShell(cmd, Redirect.stdout);
        string[] lines;
        foreach (line; p.stdout.byLineCopy)
            lines ~= line;
        if (wait(p.pid) == 0)
            return lines;
        stderr.writeln("streaming-table: command exited non-zero: ", cmd,
            "\n  Falling back to generated output.");
    }
    catch (ProcessException e)
        stderr.writeln("streaming-table: could not run command (", cmd, "): ", e.msg,
            "\n  Falling back to generated output.");
    return null;
}
