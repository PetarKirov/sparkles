/++
Shared byte-emission helpers used by every renderer, so they encode a given
picture identically — the diff strategy is the only thing that varies.

`paintRow`/`paintFull` emit absolutely-positioned rows (the full-repaint path,
also used by the diffing renderers on the first frame and on resize).
`serializeRow` emits a row's styled bytes with no cursor positioning (the unit the
line-diff renderer compares and re-emits).
+/
module sparkles.tui_render_bench.render_util;

import sparkles.base.term_control : writeCursorTo;
import sparkles.tui_render_bench.cell : Cell, Grid, TermStyle, writeStyle;
import sparkles.tui_render_bench.sink : Sink;

/// Emit a row's cells (style coalesced per run, wide-glyph continuations
/// skipped), with no cursor positioning. The first cell always emits its style
/// (a full `ESC[0;…m`), so the row is self-establishing.
void serializeRow(ref Sink s, in Cell[] row) @safe nothrow
{
    bool first = true;
    TermStyle cur;
    foreach (const ref Cell c; row)
    {
        if (c.width == 0)
            continue; // wide-glyph continuation — occupies no bytes
        if (first || c.style != cur)
        {
            writeStyle(s, c.style);
            cur = c.style;
            first = false;
        }
        s.put(c.grapheme);
    }
}

/// Emit one absolutely-positioned row: `CUP(y+1,1)` then the serialized row.
void paintRow(ref Sink s, in Grid g, ushort y) @safe nothrow
{
    writeCursorTo(s, cast(uint)(y + 1), 1);
    s.cursorMoves++;
    serializeRow(s, g.row(y));
}

/// Full repaint: every row absolutely positioned, then park in the default style.
void paintFull(ref Sink s, in Grid g) @safe nothrow
{
    foreach (ushort y; 0 .. g.rows)
        paintRow(s, g, y);
    writeStyle(s, TermStyle.init);
}
