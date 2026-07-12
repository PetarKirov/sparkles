/++
The line-diff renderer (Bubble Tea lineage).

Each frame is serialized into a buffer of fully-styled byte-lines; the previous
frame is kept in a ping-pong buffer; a row that is byte-identical to last frame is
skipped, and a changed row is re-emitted whole (absolute cursor position + the row
bytes). Damage tracking is at whole-line granularity: a one-cell change re-sends
its entire line and all that line's SGR. Buffers are reused, so steady state is
allocation-free.
+/
module sparkles.tui_render_bench.pocs.line_diff;

import sparkles.base.term_control : writeCursorTo;
import sparkles.tui_render_bench.cell : Grid;
import sparkles.tui_render_bench.render_util : serializeRow;
import sparkles.tui_render_bench.sink : Sink;

/// Line-diff renderer.
struct LineDiff
{
    /// Stable label for reports.
    enum string label = "line_diff";

    private
    {
        Sink[2] _scratch; // ping-pong serialized-frame buffers (counters unused)
        size_t[][2] _off; // per-buffer row offsets, length rows+1
        int _cur;
        ushort _cols;
        ushort _rows;
        bool _setup;
        bool _havePrev;
    }

    /// Reset per-scenario state.
    void reset(ushort cols, ushort rows) @safe nothrow
    {
        _cur = 0;
        _cols = 0;
        _rows = 0;
        _setup = false;
        _havePrev = false;
        _scratch[0].resetAll();
        _scratch[1].resetAll();
    }

    /// Emit only the rows that changed since last frame.
    void renderFrame(in Grid g, ref Sink s) @safe nothrow
    {
        if (!_setup)
        {
            s.put("\x1b[?7l");
            _setup = true;
        }
        const resized = g.cols != _cols || g.rows != _rows;
        const c = _cur;
        const p = 1 - _cur;

        serializeInto(_scratch[c], _off[c], g);
        const havePrev = _havePrev && !resized;

        foreach (ushort y; 0 .. g.rows)
        {
            const rowBytes = _scratch[c].frame[_off[c][y] .. _off[c][y + 1]];
            const changed = !havePrev
                || y + 1 >= _off[p].length
                || rowBytes != _scratch[p].frame[_off[p][y] .. _off[p][y + 1]];
            if (changed)
            {
                writeCursorTo(s, cast(uint)(y + 1), 1);
                s.cursorMoves++;
                s.put(rowBytes);
            }
        }

        _cols = g.cols;
        _rows = g.rows;
        _havePrev = true;
        _cur = p;
    }
}

private void serializeInto(ref Sink scratch, ref size_t[] off, in Grid g) @safe nothrow
{
    scratch.reset();
    if (off.length < g.rows + 1)
        off.length = g.rows + 1;
    foreach (ushort y; 0 .. g.rows)
    {
        off[y] = scratch.length;
        serializeRow(scratch, g.row(y));
    }
    off[g.rows] = scratch.length;
}
