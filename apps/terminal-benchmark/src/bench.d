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
