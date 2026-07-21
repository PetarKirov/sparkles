/++
The 2-D cell-grid renderer (Ratatui / libvaxis / Notcurses lineage).

The previous frame is retained as a full cell grid; the current target is diffed
cell by cell; runs of changed cells are emitted as one absolute cursor move
followed by the run's styled graphemes (the cursor auto-advances within a run,
style coalesced). Damage tracking is at cell granularity: a one-cell change emits
just that cell (plus a cursor move and its style). The retained grid reuses its
capacity, so steady state is allocation-free.
+/
module sparkles.tui_render_bench.pocs.cell_grid;

import sparkles.base.term_control : writeCursorTo;
import sparkles.tui_render_bench.cell : Grid, TermStyle, writeStyle;
import sparkles.tui_render_bench.render_util : paintFull;
import sparkles.tui_render_bench.sink : Sink;

/// Cell-grid renderer.
struct CellGrid
{
    /// Stable label for reports.
    enum string label = "cell_grid";

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

    /// Emit only the cell runs that changed since last frame.
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
        {
            ushort x = 0;
            while (x < g.cols)
            {
                if (g.at(x, y) == _prev.at(x, y))
                {
                    x++;
                    continue;
                }
                // A run of changed cells: one cursor move, then the run's bytes.
                writeCursorTo(s, cast(uint)(y + 1), cast(uint)(x + 1));
                s.cursorMoves++;
                bool first = true;
                TermStyle cur;
                while (x < g.cols && g.at(x, y) != _prev.at(x, y))
                {
                    const c = g.at(x, y);
                    if (c.width == 0)
                    {
                        x++;
                        continue; // wide-glyph continuation — no bytes, cursor already advanced
                    }
                    if (first || c.style != cur)
                    {
                        writeStyle(s, c.style);
                        cur = c.style;
                        first = false;
                    }
                    s.put(c.grapheme);
                    x++;
                }
            }
        }

        _prev.copyFrom(g);
    }
}
