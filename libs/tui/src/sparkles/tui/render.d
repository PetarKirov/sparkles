/++
The 2-D cell-grid renderer (Ratatui / libvaxis / Notcurses lineage) — the render
core chosen by the [render-cost benchmark](../../../../../docs/specs/tui/render-bench-baseline.md).

A $(LREF Screen) retains the previously-rendered $(LREF Grid); each frame it diffs
the new target grid against it cell by cell and emits, for every run of changed
cells, one absolute cursor move followed by the run's styled graphemes (the cursor
auto-advances within a run, style coalesced per style-run). Damage tracking is at
cell granularity: a one-cell change emits just that cell (a cursor move, its
style, and the grapheme). The retained grid reuses its capacity, so a steady
render loop allocates nothing.

The renderer writes into any `char` output range, so it composes with an
in-memory buffer (for tests / a frame buffer) or a terminal backend
($(MREF sparkles,tui,terminal)) equally.
+/
module sparkles.tui.render;

import std.range.primitives : put;

import sparkles.base.term_control : writeCursorTo;
import sparkles.base.text.writers : writeInteger;
import sparkles.tui.cell : Cell, CellStyle, ColorDepth, Grid, writeStyle;

/// The retained-grid diff renderer. Hold one per output surface; call
/// $(LREF render) each frame with the freshly-painted target grid.
struct Screen
{
    private
    {
        Grid _prev;
        bool _havePrev;
    }

    /// Forget the retained frame so the next $(LREF render) repaints in full
    /// (call after the terminal was written to out-of-band, or on a hard redraw).
    void invalidate() @safe nothrow
    {
        _havePrev = false;
    }


    /// Diff `target` against the retained frame and emit the minimal byte stream
    /// into `w`. The first frame (and any resize) repaints fully; afterwards only
    /// changed cell runs are written. `target` becomes the new retained frame.
    void render(Writer)(in Grid target, ref Writer w)
    {
        const resized = target.cols != _prev.cols || target.rows != _prev.rows;
        if (!_havePrev || resized)
        {
            paintFull(w, target, ColorDepth.trueColor);
            _prev = target;
            _havePrev = true;
            return;
        }


        // The emitted style is tracked across the whole frame, not reset per
        // changed run: a cursor move (CUP) does not reset the terminal's SGR
        // state, so a run whose style matches the last one emitted needs no new
        // `ESC[…m`. This matters for scrolled / churned content, where the diff
        // fragments into many short runs that would otherwise each re-establish
        // the same style.
        bool haveStyle;
        CellStyle cur;
        foreach (ushort y; 0 .. target.rows)
        {
            ushort x = 0;
            while (x < target.cols)
            {
                if (target[x, y] == _prev[x, y])
                {
                    x++;
                    continue;
                }
                // A run of changed cells: one cursor move, then the run's bytes.
                writeCursorTo(w, cast(uint)(y + 1), cast(uint)(x + 1));
                while (x < target.cols && target[x, y] != _prev[x, y])
                {
                    const c = target[x, y];
                    if (c.width == 0)
                    {
                        x++;
                        continue; // wide-glyph continuation — no bytes, cursor advanced
                    }
                    if (!haveStyle || c.style != cur)
                    {
                        writeStyle(w, c.style, ColorDepth.trueColor);
                        cur = c.style;
                        haveStyle = true;
                    }
                    put(w, c.grapheme);
                    x++;
                }
            }
        }

        _prev = target;
    }

}

/// Emit a row's cells (style coalesced per run, wide-glyph continuations
/// skipped), folded to `depth`, with no cursor positioning. The first cell always
/// emits its style (a full `ESC[0;…m`), so the row is self-establishing.
void serializeRow(Writer)(ref Writer w, in Cell[] row, ColorDepth depth = ColorDepth.trueColor)
{
    bool first = true;
    CellStyle cur;
    foreach (const ref c; row)
    {
        if (c.width == 0)
            continue; // wide-glyph continuation — occupies no bytes
        if (first || c.style != cur)
        {
            writeStyle(w, c.style, depth);
            cur = c.style;
            first = false;
        }
        put(w, c.grapheme);
    }
}

/// Emit one absolutely-positioned row: `CUP(y+1,1)` then the serialized row.
void paintRow(Writer)(ref Writer w, in Grid g, ushort y, ColorDepth depth = ColorDepth.trueColor)
{
    writeCursorTo(w, cast(uint)(y + 1), 1);
    serializeRow(w, g.row(y), depth);
}

/// Full repaint: every row absolutely positioned, then park in the default style.
void paintFull(Writer)(ref Writer w, in Grid g, ColorDepth depth = ColorDepth.trueColor)
{
    foreach (ushort y; 0 .. g.rows)
        paintRow(w, g, y, depth);
    writeStyle(w, CellStyle.init, depth);
}

@("render.screen.fullThenDiff")
@safe nothrow
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.tui.cell : Cell, CellStyle;
    import std.algorithm.searching : canFind, count;

    Grid g;
    g.resize(4, 2);
    g.putText(0, 0, "ab", CellStyle.init);

    Screen scr;
    SmallBuffer!char first;
    scr.render(g, first);
    // First frame repaints in full — positions both rows.
    assert(first[].canFind("ab"), first[]);
    assert(first[].canFind("\x1b[1;1H")); // CUP row 1
    assert(first[].canFind("\x1b[2;1H")); // CUP row 2

    // Change a single cell; the diff must emit only that cell + one cursor move.
    g[1, 0].setCodepoint('X', 1, CellStyle.init);
    SmallBuffer!char diff;
    scr.render(g, diff);
    assert(diff[].canFind("X"), diff[]);
    assert(diff[].canFind("\x1b[1;2H"), diff[]); // moved to the changed column
    assert(!diff[].canFind("\x1b[2;1H"));        // row 2 unchanged → not re-emitted
    // exactly one cursor move for a single-run change
    assert(diff[].count("\x1b[") >= 1);
}

@("render.screen.noChangeEmitsNothing")
@safe nothrow
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.tui.cell : CellStyle;

    Grid g;
    g.resize(3, 1);
    g.putText(0, 0, "hi", CellStyle.init);

    Screen scr;
    SmallBuffer!char a;
    scr.render(g, a);
    SmallBuffer!char b;
    scr.render(g, b); // identical frame → no output
    assert(b[].length == 0, b[]);
}

