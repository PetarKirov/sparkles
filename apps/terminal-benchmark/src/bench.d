/// Pure, testable pieces of the benchmark harness: the scenario definitions and
/// the deterministic escape-sequence workload generators. Kept separate from
/// `app.d` (which holds `main` and the process/measurement plumbing) so the unit
/// tests build as a library without pulling in `main`.
module bench;

import std.array : appender;
import std.format : format;
import std.path : buildPath;

/// What a measurement run exercises.
enum Scenario
{
    /// Paint a dense screen once, then hold — measures idle cost (dirty-skip).
    idle,
    /// Paint a dense screen, then force a redraw every frame — isolates the
    /// render path (the harness sets `SPARKLES_BENCH_FORCE_REDRAW`).
    render,
    /// Repaint the grid continuously — whole-stack throughput (parse-bound).
    churn,
}

/// A dense full screen: every cell carries a bold+italic+underline glyph with a
/// distinct 256-color fg/bg, the heaviest per-cell draw the renderer supports.
/// Painted once, with the cursor parked, so nothing changes afterwards (idle).
string fillStream(int cols, int rows) @safe
{
    auto w = appender!string;
    w ~= "\x1b[2J\x1b[H";
    foreach (line; 1 .. rows + 1)
    {
        w ~= format("\x1b[%d;1H", line);
        foreach (col; 1 .. cols + 1)
        {
            const index = line + col;
            const fg = index % 156 + 100;
            const bg = 255 - index % 156 + 100;
            const ch = cast(char)('A' + (index % 26));
            w ~= format("\x1b[38;5;%d;48;5;%d;1;3;4m%c", fg, bg, ch);
        }
    }
    w ~= "\x1b[H";
    return w[];
}

@("bench.fillStream.shape")
@safe unittest
{
    import std.algorithm : startsWith, endsWith, count;

    const s = fillStream(3, 2);
    assert(s.startsWith("\x1b[2J\x1b[H")); // clear + home
    assert(s.endsWith("\x1b[H"));          // cursor parked at the end
    // One cursor-to-line move per row.
    assert(s.count("\x1b[1;1H") == 1);
    assert(s.count("\x1b[2;1H") == 1);
    // One SGR per cell (rows * cols).
    assert(s.count("\x1b[38;5;") == 3 * 2);
}

/// vtebench-style `dense_cells`: repaint the entire grid `passes` times, cycling
/// the glyph and colors each pass so every frame the renderer draws is a full,
/// distinct repaint. Wrapped in the alternate screen.
string denseStream(int cols, int rows, int passes) @safe
{
    auto w = appender!string;
    w ~= "\x1b[?1049h";
    int offset = 0;
    foreach (_; 0 .. passes)
    {
        foreach (ch; "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        {
            w ~= "\x1b[H";
            foreach (line; 1 .. rows + 1)
                foreach (col; 1 .. cols + 1)
                {
                    const index = line + col + offset;
                    const fg = index % 156 + 100;
                    const bg = 255 - index % 156 + 100;
                    w ~= format("\x1b[38;5;%d;48;5;%d;1;3;4m%c", fg, bg, ch);
                }
            offset++;
        }
    }
    w ~= "\x1b[?1049l";
    return w[];
}

@("bench.denseStream.shape")
@safe unittest
{
    import std.algorithm : startsWith, endsWith, count;

    const s = denseStream(4, 3, 2);
    assert(s.startsWith("\x1b[?1049h")); // enter alt screen
    assert(s.endsWith("\x1b[?1049l"));   // leave alt screen
    // 26 glyphs per pass * 2 passes = 52 full-grid repaints (one home each).
    assert(s.count("\x1b[H") == 26 * 2);
    // rows * cols * 26 * passes cells painted.
    assert(s.count("\x1b[38;5;") == 4 * 3 * 26 * 2);
}

/// The shell command run inside the terminal for a scenario. The terminal joins
/// trailing args and runs them via `$SHELL -c`, so a single string is fine.
string workload(Scenario s, string streamDir) @safe
{
    final switch (s)
    {
        case Scenario.idle:
        case Scenario.render:
            // Paint once, then sit idle well past the measurement window. The
            // render scenario additionally forces a redraw every frame via the
            // env var set in `measure`, so the same static screen exercises the
            // full render path instead of being skipped.
            return format("cat %s; sleep 600", buildPath(streamDir, "fill.vt"));
        case Scenario.churn:
            // Repaint continuously for the whole run.
            return format("while :; do cat %s; done", buildPath(streamDir, "dense.vt"));
    }
}

@("bench.workload.streams")
@safe unittest
{
    import std.algorithm : canFind;

    assert(workload(Scenario.idle, "/tmp/d").canFind("cat /tmp/d/fill.vt"));
    assert(workload(Scenario.render, "/tmp/d").canFind("cat /tmp/d/fill.vt"));
    assert(workload(Scenario.churn, "/tmp/d").canFind("/tmp/d/dense.vt"));
    assert(workload(Scenario.churn, "/tmp/d").canFind("while :;"));
}

/// Human-readable label for the results table.
string scenarioName(Scenario s) @safe
{
    final switch (s)
    {
        case Scenario.idle:   return "idle (static screen)";
        case Scenario.render: return "render (forced redraw)";
        case Scenario.churn:  return "churn (full repaint)";
    }
}

@("bench.scenarioName.labels")
@safe unittest
{
    assert(scenarioName(Scenario.idle) == "idle (static screen)");
    assert(scenarioName(Scenario.render) == "render (forced redraw)");
    assert(scenarioName(Scenario.churn) == "churn (full repaint)");
}

// --- Write-to-photon latency (output-latency.md OPL26) ----------------------

/// One write the probe made: where it started in the stream, how long it was,
/// and when it was made (`CLOCK_MONOTONIC` nanoseconds).
struct WriteRecord
{
    ulong offset; ///
    uint length;  ///
    long ns;      ///
}

/// One frame of the terminal's `--debug latency-log`: when it started and was
/// shown (-1: never), and the stream bytes delivered before it started.
struct FrameLine
{
    ulong number;   ///
    long startNs;   ///
    long shownNs;   ///
    ulong position; ///
}

/// The latency distribution of a run, in milliseconds.
struct LatencyStats
{
    size_t writes;     /// writes the probe made
    size_t measured;   /// writes a shown frame included
    size_t neverShown; /// writes no shown frame included
    size_t superseded; /// writes whose first frame was not shown, a later one was
    double p50 = 0, p95 = 0, p99 = 0, max = 0; ///
}

/// Parses tab-separated lines of `N` integer columns, skipping a header and
/// blank lines.
private long[N][] parseColumns(size_t N)(string tsv) @safe
{
    import std.algorithm : splitter;
    import std.conv : ConvException, to;
    import std.string : lineSplitter, strip;

    long[N][] rows;
    foreach (line; tsv.lineSplitter)
    {
        if (line.strip.length == 0)
            continue;
        long[N] row;
        size_t i;
        bool ok = true;
        foreach (field; line.splitter('\t'))
        {
            if (i == N)
                break;
            try
                row[i++] = field.strip.to!long;
            catch (ConvException)
            {
                ok = false;
                break;
            }
        }
        if (ok && i == N)
            rows ~= row;
    }
    return rows;
}

/// The probe's log: `offset length ns` per line.
WriteRecord[] parseWrites(string tsv) @safe
{
    WriteRecord[] w;
    foreach (r; parseColumns!3(tsv))
        w ~= WriteRecord(r[0], cast(uint) r[1], r[2]);
    return w;
}

/// The terminal's latency log: `frame start_ns shown_ns stream_position`.
FrameLine[] parseFrames(string tsv) @safe
{
    FrameLine[] f;
    foreach (r; parseColumns!4(tsv))
        f ~= FrameLine(r[0], r[1], r[2], r[3]);
    return f;
}

/**
Joins the probe's writes to the frames that showed them. A write is shown by
the first frame whose stream position covers its last byte; where that frame
was never shown, by the first later frame that was (the write counts as
superseded); where none was, it counts as never shown.
*/
LatencyStats joinLatency(const(WriteRecord)[] writes, const(FrameLine)[] frames) @safe
{
    import std.algorithm : sort;

    LatencyStats s;
    s.writes = writes.length;
    double[] ms;
    size_t f; // frames are in start order, their positions non-decreasing
    foreach (w; writes)
    {
        const end = w.offset + w.length;
        while (f < frames.length && frames[f].position < end)
            ++f;
        size_t g = f;
        while (g < frames.length && frames[g].shownNs < 0)
            ++g;
        if (g == frames.length)
        {
            ++s.neverShown;
            continue;
        }
        if (g != f)
            ++s.superseded;
        ++s.measured;
        ms ~= (frames[g].shownNs - w.ns) / 1e6;
    }
    if (ms.length)
    {
        ms.sort();
        double at(double q) => ms[cast(size_t) ((ms.length - 1) * q + 0.5)];
        s.p50 = at(0.50);
        s.p95 = at(0.95);
        s.p99 = at(0.99);
        s.max = ms[$ - 1];
    }
    return s;
}

@("bench.joinLatency.firstCoveringShownFrame")
@safe unittest
{
    // Writes of 10 bytes at 0, 10 and 20 ms; frames shown at 16 and 33 ms
    // covering 10 and 30 bytes; a third, covering nothing more, never shown.
    const writes = [WriteRecord(0, 10, 0), WriteRecord(10, 10, 10_000_000),
        WriteRecord(20, 10, 20_000_000)];
    const frames = [FrameLine(0, 1_000_000, 16_000_000, 10),
        FrameLine(1, 18_000_000, 33_000_000, 30), FrameLine(2, 40_000_000, -1, 30)];
    const s = joinLatency(writes, frames);
    assert(s.writes == 3 && s.measured == 3 && s.neverShown == 0);
    // 16 ms (frame 0), 23 and 13 ms (both frame 1, shown at 33 ms).
    assert(s.p50 == 16.0, "the median of 13, 16 and 23");
    assert(s.max == 23.0 && s.p99 == 23.0);
}

@("bench.joinLatency.supersededAndNeverShown")
@safe unittest
{
    const writes = [WriteRecord(0, 4, 0), WriteRecord(4, 4, 0)];
    // Frame 0 covers the first write but was superseded; frame 1 shows it.
    // Nothing covers the second write.
    const frames = [FrameLine(0, 0, -1, 4), FrameLine(1, 0, 20_000_000, 4)];
    const s = joinLatency(writes, frames);
    assert(s.measured == 1 && s.superseded == 1 && s.neverShown == 1);
    assert(s.p50 == 20.0);
}

@("bench.parse.latencyLogs")
@safe unittest
{
    const f = parseFrames("frame\tstart_ns\tshown_ns\tstream_position\n7\t100\t-1\t42\n");
    assert(f == [FrameLine(7, 100, -1, 42)]);
    const w = parseWrites("0\t5\t99\n5\t3\t120\n");
    assert(w == [WriteRecord(0, 5, 99), WriteRecord(5, 3, 120)]);
}
