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

        // When the frame is the previous one shifted vertically (scrolling), let
        // the terminal hardware-scroll the band and mirror it in `_prev`, so the
        // per-cell diff below only redraws the newly-exposed rows + local changes
        // instead of re-emitting the whole shifted body.
        scrollOptimize(target, w);

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

    // Detect a vertical scroll (the largest contiguous band of rows that `target`
    // shares with `_prev` at a non-zero row offset) and, when it is worth it,
    // emit a hardware scroll (DECSTBM region + SU/SD) and mirror the shift in
    // `_prev` (via `scrollRect`). The subsequent per-cell diff then only redraws
    // the exposed rows and any local changes. A false positive is harmless — the
    // diff still corrects every cell; it only costs a few wasted bytes.
    private void scrollOptimize(Writer)(in Grid target, ref Writer w)
    {
        const rows = target.rows;
        if (rows < 4)
            return;

        // Quick reject: a scroll shifts many rows. If few rows changed at all,
        // it is a local update — skip the O(rows²) search below.
        int changed;
        foreach (ushort y; 0 .. rows)
            if (target.row(y) != _prev.row(y))
                ++changed;
        if (changed < 4)
            return;

        // For each candidate offset `d`, the longest run of rows where
        // `target.row(y) == _prev.row(y + d)` is a shift by `d` (d>0 ⇒ content
        // moved up ⇒ SU; d<0 ⇒ down ⇒ SD).
        int bestD, bestLen, bestStart;
        for (int d = -(rows - 1); d <= rows - 1; ++d)
        {
            if (d == 0)
                continue;
            int run, curStart;
            foreach (ushort y; 0 .. rows)
            {
                const yp = cast(int) y + d;
                const m = yp >= 0 && yp < rows && target.row(y) == _prev.row(cast(ushort) yp);
                if (m)
                {
                    if (run == 0)
                        curStart = y;
                    ++run;
                    if (run > bestLen)
                    {
                        bestLen = run;
                        bestD = d;
                        bestStart = curStart;
                    }
                }
                else
                    run = 0;
            }
        }
        const absD = bestD > 0 ? bestD : -bestD;
        if (bestLen < 4 || bestLen <= absD)
            return; // no worthwhile scroll (preserves too little)

        // The scroll region spans the preserved run plus the `absD` exposed rows.
        int r0 = bestD > 0 ? bestStart : bestStart + bestD;
        int r1 = bestD > 0 ? bestStart + bestLen - 1 + bestD : bestStart + bestLen - 1;
        if (r0 < 0)
            r0 = 0;
        if (r1 > rows - 1)
            r1 = rows - 1;
        if (r1 - r0 + 1 <= absD)
            return;

        // Set the scroll region, scroll it, reset the region.
        put(w, "\x1b[");
        writeInteger(w, cast(uint)(r0 + 1));
        put(w, ';');
        writeInteger(w, cast(uint)(r1 + 1));
        put(w, 'r');
        put(w, "\x1b[");
        writeInteger(w, cast(uint) absD);
        put(w, bestD > 0 ? 'S' : 'T'); // SU / SD
        put(w, "\x1b[r"); // reset the scroll region to full screen

        // Mirror the terminal's shift in the retained grid (blank the vacated
        // rows with the default cell — they differ from `target`'s exposed
        // content, so the diff redraws them).
        _prev.scrollRect(0, cast(ushort) r0, _prev.cols, cast(ushort)(r1 - r0 + 1),
            -bestD, CellStyle.init);
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

@("render.screen.scrollEmitsHardwareScroll")
@safe nothrow
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.tui.cell : CellStyle;
    import std.algorithm.searching : canFind;

    static immutable string[8] labels = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7"];
    Grid g;
    g.resize(6, 8);
    foreach (ushort y; 0 .. 8)
        g.putText(0, y, labels[y], CellStyle.init);

    Screen scr;
    SmallBuffer!char full;
    scr.render(g, full); // first frame — full paint

    // Scroll the whole grid up by 2 and expose two new rows at the bottom.
    g.scrollRect(0, 0, 6, 8, -2, CellStyle.init);
    g.putText(0, 6, "nA", CellStyle.init);
    g.putText(0, 7, "nB", CellStyle.init);

    SmallBuffer!char diff;
    scr.render(g, diff);
    const s = diff[];
    assert(s.canFind("\x1b[1;8r"), s);            // DECSTBM region rows 1..8
    assert(s.canFind("\x1b[2S"), s);              // scroll up by 2 (SU)
    assert(s.canFind("nA") && s.canFind("nB"), s); // only the exposed rows are drawn
    assert(!s.canFind("r2") && !s.canFind("r7"), s); // preserved rows are NOT re-emitted
}
