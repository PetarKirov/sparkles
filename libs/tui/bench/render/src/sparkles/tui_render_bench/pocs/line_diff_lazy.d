/++
The lazy line-diff renderer — the M1 sensitivity variant.

M1 showed the naive `line_diff` executes the same instruction count as a full
repaint: it serializes *every* row each frame just to compare it. This variant
keeps line-diff's whole-line emission (bytes identical to `line_diff`) but detects
change by comparing the target grid's cells against a retained grid — so it
serializes only the rows that actually changed. It isolates the two axes: versus
`line_diff` (same bytes) it exposes the CPU cost of re-serializing unchanged rows;
versus `cell_grid` (same change-detection cost) it exposes the byte cost of
whole-line versus cell-run emission.
+/
module sparkles.tui_render_bench.pocs.line_diff_lazy;

import sparkles.tui_render_bench.cell : Grid;
import sparkles.tui_render_bench.render_util : paintFull, paintRow;
import sparkles.tui_render_bench.sink : Sink;

/// Lazy line-diff renderer: cell-compare rows, re-emit only changed ones whole.
struct LineDiffLazy
{
    /// Stable label for reports.
    enum string label = "line_diff_lazy";

    private
    {
        Grid _prev;
        bool _setup;
        bool _havePrev;
    }

    /// Reset per-scenario state.
    void reset(ushort cols, ushort rows) @safe nothrow
    {
        _setup = false;
        _havePrev = false;
    }

    /// Emit whole rows, but only those whose cells changed since last frame.
    void renderFrame(in Grid g, ref Sink s) @safe nothrow
    {
        if (!_setup)
        {
            s.put("\x1b[?7l");
            _setup = true;
        }
        const resized = g.cols != _prev.cols || g.rows != _prev.rows;
        if (!_havePrev || resized)
        {
            paintFull(s, g);
            _prev.copyFrom(g);
            _havePrev = true;
            return;
        }

        foreach (ushort y; 0 .. g.rows)
            if (g.row(y) != _prev.row(y)) // cheap cell compare, no serialization
                paintRow(s, g, y);

        _prev.copyFrom(g);
    }
}
