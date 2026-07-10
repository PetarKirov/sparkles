#!/usr/bin/env dub
/+ dub.sdl:
name "table-bench-ticker"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
+/

module table_bench_ticker_example;

// A benchmark ticker: real Phobos micro-workloads are measured one after
// another, and the results table grows a row as each measurement completes —
// repainted in place by a `LiveRegion`, with a braille spinner row for the
// benchmark currently in flight. The time/iter column is `Align.decimal`
// (dots share a cell) and the relative column is a bar scaled against the
// fastest result so far, recomputed every repaint.
//
// Layout is per-frame, so a growing table would re-derive its column widths
// every repaint and visibly jump as longer names and the first bar arrive;
// `TableProps.columnMinWidths` floors computed from the roster up front
// (`stableMinWidths`) pin the geometry so no frame resizes.
//
// Measurement is interleaved, not threaded: iterations run in small batches
// between repaints, so the work itself paces the animation. The numbers are
// illustrative (a debug build, clock reads in the loop) — the demo is about
// the table, not the benchmarks; use sparkles:test-runner --bench for real
// measurements.
//
// Piped (non-tty) output skips the animation and prints the final table once.
//
//   dub run --single table-bench-ticker.d
//   dub run --single table-bench-ticker.d -- --budget-ms 400
//   dub run --single table-bench-ticker.d -- --budget-ms 20 --interval 0

import core.time : Duration, dur;
import std.algorithm.comparison : max, min;
import std.conv : text;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.format : format;
import std.stdio : write;

import sparkles.core_cli.args;
import sparkles.core_cli.ui.live : stdoutLiveRegion;
import sparkles.core_cli.ui.table : drawTable, drawTableLines, TableProps;
import sparkles.base.styled_template : styledText;
import sparkles.base.text.width : Align;

struct CliParams
{
    @CliOption("b|budget-ms", "Measurement budget per benchmark, in milliseconds")
    int budgetMs = 150;

    @CliOption("i|interval", "Milliseconds of measuring between repaints")
    int intervalMs = 80;
}

/// Cells in the relative column's bar when at full (= fastest) length.
enum fullBar = 12;

/// A micro-workload: one call of `op` is one iteration; the returned value is
/// folded into a sink so the work cannot be optimized away.
struct Bench
{
    string name;
    ulong delegate() op;
}

/// ditto
struct BenchResult
{
    string name;
    ulong iterations;
    double nsPerIter;
}

void main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(HelpInfo(
        "table-bench-ticker",
        "Benchmark results ticking into a live table as they complete"));

    auto region = stdoutLiveRegion();
    scope (exit) region.finish();

    const budget = dur!"msecs"(max(cli.budgetMs, 1));
    const frameSlice = dur!"msecs"(max(cli.intervalMs, 1));

    auto benches = makeBenches();
    // Pin the geometry before the first frame: without floors every repaint
    // re-derives column widths from the rows present so far, so the table
    // visibly jumps as longer names and the first bar arrive (flicker).
    const minWidths = stableMinWidths(benches);

    BenchResult[] results;
    ulong sink;
    size_t spin;
    foreach (bench; benches)
    {
        auto sw = StopWatch(AutoStart.yes);
        ulong iters;
        while (sw.peek < budget)
        {
            // One batch of iterations, then a repaint — the measurement itself
            // paces the spinner.
            const frameEnd = min(sw.peek + frameSlice, budget);
            while (sw.peek < frameEnd)
            {
                sink ^= bench.op();
                ++iters;
            }
            if (region.interactive)
                region.update(frameLines(results, bench.name, spin++,
                    cli.budgetMs, minWidths));
        }
        const elapsed = sw.peek;
        results ~= BenchResult(bench.name, iters,
            iters ? cast(double) elapsed.total!"nsecs" / iters : double.nan);
        if (region.interactive)
            region.update(frameLines(results, null, spin, cli.budgetMs, minWidths));
    }

    // Piped runs saw no frames; print the final table once. The sink is part
    // of the output so the measured work stays observable.
    if (!region.interactive)
        write(drawTable(resultCells(results, null, 0),
            frameProps(cli.budgetMs, minWidths)));
    if (sink == 0)
        write("(sink: 0)\n"); // practically never; keeps `sink` live

    region.finish();
}

/// One frame: the results so far plus a spinner row for the in-flight
/// benchmark (`inflight: null` once everything completed).
string[] frameLines(BenchResult[] results, string inflight, size_t spin,
    int budgetMs, in size_t[] minWidths)
{
    import std.array : array;

    return drawTableLines(resultCells(results, inflight, spin),
        frameProps(budgetMs, minWidths)).array;
}

/// Column-width floors that keep the live table's geometry constant across
/// frames: the benchmark column already fits every roster name plus the
/// spinner prefix, and the relative column fits the fastest row's full bar
/// plus its `1.0×` label before the first result lands. The other columns are
/// stable through their headers alone (`iterations` == `measuring…` == 10
/// cells; `time/iter` covers `888.88µs`).
size_t[] stableMinWidths(Bench[] benches)
{
    import sparkles.base.text.grapheme : visibleWidth;

    size_t name;
    foreach (ref b; benches)
        name = max(name, visibleWidth(b.name));
    return [name + 2, 0, 0, fullBar + 1 + visibleWidth("1.0×")];
}

/// ditto
string[][] resultCells(BenchResult[] results, string inflight, size_t spin)
{
    import std.algorithm.iteration : map;
    import std.algorithm.searching : minElement;

    string[][] cells = [[
        styledText(i"{bold benchmark}"),
        styledText(i"{bold iterations}"),
        styledText(i"{bold time/iter}"),
        styledText(i"{bold relative}"),
    ]];
    const fastest = results.length
        ? results.map!(r => r.nsPerIter).minElement : double.nan;
    foreach (ref r; results)
        cells ~= [r.name, text(r.iterations), fmtNanos(r.nsPerIter),
            relativeBar(r.nsPerIter, fastest)];
    if (inflight.length)
    {
        static immutable dchar[] frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"d;
        const glyph = frames[spin % $];
        cells ~= [styledText(i"{dim $(glyph) $(inflight)}"),
            styledText(i"{dim measuring…}"), "", ""];
    }
    return cells;
}

/// ditto
TableProps frameProps(int budgetMs, in size_t[] minWidths)
{
    return TableProps(
        headerRows: 1,
        title: styledText(i"{bold Micro-benchmarks}"),
        footer: text("~", budgetMs, " ms budget each"),
        columnAligns: [Align.left, Align.right, Align.decimal, Align.left],
        columnMinWidths: minWidths.dup,
    );
}

/// `1234.5` → `1.23µs`: two decimals and a two-cell unit, so the decimal
/// column's dots share a cell across ns/µs/ms results.
string fmtNanos(double ns)
{
    if (ns < 1_000)
        return format!"%.2fns"(ns);
    if (ns < 1_000_000)
        return format!"%.2fµs"(ns / 1_000);
    return format!"%.2fms"(ns / 1_000_000);
}

/// A bar scaled against the fastest result (full bar = fastest, shorter =
/// slower) plus the slowdown factor. Log-scaled: micro-benchmark spreads span
/// several orders of magnitude, so a linear bar would collapse everything but
/// the winner to one cell.
string relativeBar(double ns, double fastest)
{
    import std.math.exponential : log2;

    const slowdown = ns / fastest;
    const cells = max(1, fullBar - cast(int) (log2(slowdown) * 1.25 + 0.5));
    string bar;
    foreach (_; 0 .. cells)
        bar ~= "█";
    const label = format!"%.1f×"(slowdown);
    return styledText(i"{cyan $(bar)} {dim $(label)}");
}

/// The workload roster: small, self-contained Phobos ops over inputs built
/// once (the delegates close over them), each returning a value for the sink.
Bench[] makeBenches()
{
    import std.algorithm.iteration : map, sum;
    import std.algorithm.sorting : sort;
    import std.array : appender;
    import std.digest.md : md5Of;
    import std.random : Mt19937, uniform;
    import std.range : iota;
    import std.regex : matchAll, regex;

    auto rng = Mt19937(1234);
    auto ints = new int[10_000];
    foreach (ref x; ints)
        x = uniform(0, 1_000_000, rng);

    auto buf = new ubyte[64 * 1024];
    foreach (i, ref b; buf)
        b = cast(ubyte) (i * 31);

    auto re = regex(`[a-z0-9]+@[a-z.]+`);
    string emails;
    foreach (i; 0 .. 200)
        emails ~= text("user", i, "@example.com lorem ipsum dolor sit amet ");

    return [
        Bench("sort 10k ints", () {
            auto a = ints.dup;
            a.sort();
            return cast(ulong) a[0];
        }),
        Bench("md5 of 64 KiB", () => cast(ulong) md5Of(buf)[0]),
        Bench("regex 200 e-mails", () {
            ulong n;
            foreach (m; emails.matchAll(re))
                ++n;
            return n;
        }),
        Bench("format 100 floats", () {
            ulong n;
            foreach (k; 0 .. 100)
                n += format!"%.3f"(k * 1.5).length;
            return n;
        }),
        Bench("append 64 KiB", () {
            auto app = appender!(ubyte[]);
            foreach (_; 0 .. 64)
                app ~= buf[0 .. 1024];
            return cast(ulong) app[].length;
        }),
        Bench("sum 100k doubles", ()
            => cast(ulong) iota(100_000).map!(x => x * 1.000001).sum),
    ];
}
