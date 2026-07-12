/++
The reference renderer: a dumb full repaint, the ground truth.

Every frame it emits the entire grid — each row absolutely positioned, style
coalesced per run. It is obviously correct (no diff logic to get wrong), so it
anchors the correctness gate: the VT-reconstructed grid from any diffing PoC must
match the target every frame, and this renderer demonstrates the target is
reachable. It is also a legitimate "no diffing at all" baseline data point.
+/
module sparkles.tui_render_bench.pocs.reference_fullpaint;

import sparkles.base.term_control : writeCursorTo;
import sparkles.tui_render_bench.cell : Cell, CellStyle, Grid, writeStyle;
import sparkles.tui_render_bench.sink : Sink;

/// Full-repaint renderer. `Name` is the row label under the benchmark.
struct ReferenceFullpaint
{
    /// Stable label for reports.
    enum string label = "reference_fullpaint";

    private bool _setup;

    /// Reset per-scenario state (re-arms the one-shot terminal setup).
    void reset(ushort cols, ushort rows) @safe nothrow
    {
        _setup = false;
    }

    /// Emit the whole grid.
    void renderFrame(in Grid g, ref Sink s) @safe nothrow
    {
        if (!_setup)
        {
            s.put("\x1b[?7l"); // autowrap off — writing the last cell must not scroll
            _setup = true;
        }

        foreach (y; 0 .. g.rows)
        {
            writeCursorTo(s, cast(uint)(y + 1), 1);
            s.cursorMoves++;

            bool first = true;
            CellStyle cur;
            foreach (const ref Cell c; g.row(cast(ushort) y))
            {
                if (c.width == 0)
                    continue; // wide-glyph continuation cell — occupies no bytes
                if (first || c.style != cur)
                {
                    writeStyle(s, c.style);
                    cur = c.style;
                    first = false;
                }
                s.put(c.grapheme);
            }
        }
        writeStyle(s, CellStyle.init); // park in the default style
    }
}

@("pocs.reference.emitsAndIsDeterministic")
@safe
unittest
{
    import sparkles.tui_render_bench.replay : replayScenario;
    import sparkles.tui_render_bench.scenario : generateScenario, Profile;

    auto scn = generateScenario(Profile.mixed, 80, 24, 20);

    ReferenceFullpaint r1, r2;
    Sink s1, s2;
    replayScenario(r1, scn, s1);
    replayScenario(r2, scn, s2);

    assert(s1.bytesTotal > 0);
    assert(s1.frame == s2.frame); // deterministic last frame
    assert(s1.bytesTotal == s2.bytesTotal);
    assert(s1.cursorMoves == s2.cursorMoves);
}
