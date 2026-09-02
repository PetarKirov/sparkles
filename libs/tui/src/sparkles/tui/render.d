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
        ColorDepth _depth = ColorDepth.trueColor;
    }

    /// Forget the retained frame so the next $(LREF render) repaints in full
    /// (call after the terminal was written to out-of-band, or on a hard redraw).
    void invalidate() @safe nothrow
    {
        _havePrev = false;
    }

    /// Fold colors to this terminal's real depth (truecolor cells degrade to the
    /// nearest 256/16 entry). The next frame repaints in full so the new depth
    /// applies uniformly.
    void colorDepth(ColorDepth d) @safe nothrow
    {
        if (d != _depth)
        {
            _depth = d;
            _havePrev = false;
        }
    }

    /**
    Diff `target` against the retained frame and emit the minimal byte stream
    into `w`. The first frame (and any resize) repaints fully; afterwards only
    changed cell runs are written. `target` becomes the new retained frame.

    `links` is the frame's OSC 8 URI table: a cell's `linkId` indexes it from
    1, and `0` means "no hyperlink". Pass none (the default) and no hyperlink
    sequence is ever emitted. A hyperlink is opened and closed $(B inside) each
    redrawn run, never across the cursor move between runs — a terminal binds
    the open link to every cell it goes on to write, so a link left open would
    capture unrelated content the diff repaints next.
    */
    void render(Writer)(in Grid target, ref Writer w,
        scope const(char)[][] links = null)
    {
        const resized = target.cols != _prev.cols || target.rows != _prev.rows;
        if (!_havePrev || resized)
        {
            paintFull(w, target, _depth, links);
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
                // Hyperlink state, unlike style, is NOT carried across the
                // cursor move that starts each run: an open link binds every
                // cell the terminal writes next, so leaving one open would
                // capture the unrelated cells of the following run.
                ushort curLink;
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
                        writeStyle(w, c.style, _depth);
                        cur = c.style;
                        haveStyle = true;
                    }
                    if (links.length)
                        writeLink(w, c.linkId, curLink, links);
                    put(w, c.grapheme);
                    x++;
                }
                if (curLink != 0)
                    writeLink(w, 0, curLink, links);
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

        // Set the scroll region, scroll it, reset the region. Upward is SU
        // (`CSI n S`). Downward is NOT SD (`CSI n T`): zellij silently
        // ignores SD — probably because `CSI Ps;…(5 params) T` doubles as
        // xterm's highlight-mouse-tracking hijack — which desyncs the
        // retained mirror and freezes every row the diff then trusts.
        // `IL` at the region's top row has the identical effect (VT102
        // baseline, no ambiguity, verified in zellij/ghostty/xterm).
        put(w, "\x1b[");
        writeInteger(w, cast(uint)(r0 + 1));
        put(w, ';');
        writeInteger(w, cast(uint)(r1 + 1));
        put(w, 'r');
        if (bestD > 0)
        {
            put(w, "\x1b[");
            writeInteger(w, cast(uint) absD);
            put(w, 'S'); // SU
        }
        else
        {
            writeCursorTo(w, cast(uint)(r0 + 1), 1); // IL needs the cursor in-region
            put(w, "\x1b[");
            writeInteger(w, cast(uint) absD);
            put(w, 'L'); // IL == SD-by-n with the cursor on the region's top row
        }
        put(w, "\x1b[r"); // reset the scroll region to full screen

        // Mirror the terminal's shift in the retained grid (blank the vacated
        // rows with the default cell — they differ from `target`'s exposed
        // content, so the diff redraws them).
        _prev.scrollRect(0, cast(ushort) r0, _prev.cols, cast(ushort)(r1 - r0 + 1),
            -bestD, CellStyle.init);
    }
}

/**
Emit the OSC 8 transition taking the hyperlink state from `cur` to `want`,
and update `cur`.

`links` is the frame's URI table, indexed from 1 — `0` means "no hyperlink",
matching the cell's own convention. An id with no entry closes rather than
opening a dangling link.

$(B Never let link state span a cursor move.) A terminal attaches the open
hyperlink to every cell it subsequently writes, so an unclosed link would
capture whatever the next positioned run paints. Callers close before every
`CUP` and at the end of a row.
*/
private void writeLink(Writer)(ref Writer w, ushort want, ref ushort cur,
    scope const(char)[][] links)
{
    if (want == cur)
        return;
    const valid = want != 0 && want <= links.length;
    put(w, "\x1b]8;;");
    if (valid)
        put(w, links[want - 1]);
    put(w, "\x1b\\");
    cur = valid ? want : 0;
}

/// Emit a row's cells (style coalesced per run, wide-glyph continuations
/// skipped), folded to `depth`, with no cursor positioning. The first cell always
/// emits its style (a full `ESC[0;…m`), so the row is self-establishing.
///
/// `links` is the frame's OSC 8 URI table (see $(LREF Screen.render)); an
/// empty one emits no hyperlink sequences at all. Any link open at the end of
/// the row is closed, so the row never leaks its state to the next one.
void serializeRow(Writer)(ref Writer w, in Cell[] row,
    ColorDepth depth = ColorDepth.trueColor, scope const(char)[][] links = null)
{
    bool first = true;
    CellStyle cur;
    ushort curLink;
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
        if (links.length)
            writeLink(w, c.linkId, curLink, links);
        put(w, c.grapheme);
    }
    if (curLink != 0)
        writeLink(w, 0, curLink, links);
}

/// Emit one absolutely-positioned row: `CUP(y+1,1)` then the serialized row.
void paintRow(Writer)(ref Writer w, in Grid g, ushort y,
    ColorDepth depth = ColorDepth.trueColor, scope const(char)[][] links = null)
{
    writeCursorTo(w, cast(uint)(y + 1), 1);
    serializeRow(w, g.row(y), depth, links);
}

/// Full repaint: every row absolutely positioned, then park in the default style.
void paintFull(Writer)(ref Writer w, in Grid g,
    ColorDepth depth = ColorDepth.trueColor, scope const(char)[][] links = null)
{
    foreach (ushort y; 0 .. g.rows)
        paintRow(w, g, y, depth, links);
    writeStyle(w, CellStyle.init, depth);
}

/// A run of linked cells is wrapped in one OSC 8 pair; the cells around it are
/// untouched, and no hyperlink escape is emitted at all without a URI table.
@("render.osc8.wrapsTheLinkedRunOnly")
@safe nothrow
unittest
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.tui.cell : CellStyle;
    import std.algorithm.searching : canFind, count;

    Grid g;
    g.resize(8, 1);
    g.putText(0, 0, "go here now", CellStyle.init);
    foreach (ushort x; 3 .. 7) // "here"
        g[x, 0].linkId = 1;

    const(char)[][] links = ["http://x"];

    SharedBuffer!char buf;
    paintRow(buf, g, 0, ColorDepth.trueColor, links);
    const s = buf[];
    assert(s.canFind("\x1b]8;;http://x\x1b\\"), s);
    assert(s.canFind("\x1b]8;;\x1b\\"), s); // closed again
    assert(s.count("\x1b]8;;") == 2, "one open + one close, not per cell");
    // The link opens immediately before the linked text and closes after it.
    assert(s.canFind("\x1b]8;;http://x\x1b\\here"), s);

    // Without a table the channel is inert.
    SharedBuffer!char plain;
    paintRow(plain, g, 0);
    assert(!plain[].canFind("\x1b]8;;"), plain[]);
}

/// A hyperlink never survives the cursor move between two redrawn runs: the
/// terminal would bind it to whatever the next run paints.
@("render.osc8.closesBeforeEachCursorMove")
@safe nothrow
unittest
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.tui.cell : CellStyle;
    import std.algorithm.searching : canFind, count;

    // `std.string.lastIndexOf` decodes UTF and so is not `nothrow`; these are
    // raw escape bytes anyway.
    static ptrdiff_t lastAt(scope const(char)[] hay, scope const(char)[] needle)
        @safe pure nothrow @nogc
    {
        if (needle.length > hay.length)
            return -1;
        for (ptrdiff_t i = hay.length - needle.length; i >= 0; --i)
            if (hay[i .. i + needle.length] == needle)
                return i;
        return -1;
    }

    Grid g;
    g.resize(8, 1);
    g.putText(0, 0, "abcdefgh", CellStyle.init);

    Screen scr;
    SharedBuffer!char first;
    const(char)[][] links = ["http://x"];
    scr.render(g, first, links);

    // Two separated cells change; only the first is linked.
    g[1, 0].setCodepoint('X', 1, CellStyle.init, 1);
    g[6, 0].setCodepoint('Y', 1, CellStyle.init, 0);
    SharedBuffer!char diff;
    scr.render(g, diff, links);
    const s = diff[];

    assert(s.count("\x1b]8;;") == 2, s); // opened and closed, once
    // The close precedes the cursor move that starts the second run.
    const closeAt = lastAt(s, "\x1b]8;;");
    const secondCup = lastAt(s, "\x1b[1;7H");
    assert(closeAt >= 0 && secondCup >= 0 && closeAt < secondCup, s);
}

/// A cell whose hyperlink changed differs, so the retained diff repaints it
/// even though its glyph and style are identical.
@("render.osc8.linkChangeRepaintsTheCell")
@safe nothrow
unittest
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.tui.cell : CellStyle;
    import std.algorithm.searching : canFind;

    Grid g;
    g.resize(4, 1);
    g.putText(0, 0, "ab", CellStyle.init);

    Screen scr;
    SharedBuffer!char first;
    const(char)[][] links = ["http://x"];
    scr.render(g, first, links);

    // Same glyph, same style — only the link differs.
    g[0, 0].setCodepoint('a', 1, CellStyle.init, 1);
    SharedBuffer!char diff;
    scr.render(g, diff, links);
    assert(diff[].canFind("\x1b]8;;http://x\x1b\\"), diff[]);
}

/// An id with no entry in the table closes rather than opening a dangling
/// hyperlink.
@("render.osc8.unknownIdDoesNotOpen")
@safe nothrow
unittest
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.tui.cell : CellStyle;
    import std.algorithm.searching : canFind;

    Grid g;
    g.resize(4, 1);
    g.putText(0, 0, "ab", CellStyle.init);
    g[0, 0].linkId = 7; // out of range

    SharedBuffer!char buf;
    paintRow(buf, g, 0, ColorDepth.trueColor, ["http://x"]);
    assert(!buf[].canFind("http://x"), buf[]);
}

@("render.screen.fullThenDiff")
@safe nothrow
unittest
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.tui.cell : Cell, CellStyle;
    import std.algorithm.searching : canFind, count;

    Grid g;
    g.resize(4, 2);
    g.putText(0, 0, "ab", CellStyle.init);

    Screen scr;
    SharedBuffer!char first;
    scr.render(g, first);
    // First frame repaints in full — positions both rows.
    assert(first[].canFind("ab"), first[]);
    assert(first[].canFind("\x1b[1;1H")); // CUP row 1
    assert(first[].canFind("\x1b[2;1H")); // CUP row 2

    // Change a single cell; the diff must emit only that cell + one cursor move.
    g[1, 0].setCodepoint('X', 1, CellStyle.init);
    SharedBuffer!char diff;
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
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.tui.cell : CellStyle;

    Grid g;
    g.resize(3, 1);
    g.putText(0, 0, "hi", CellStyle.init);

    Screen scr;
    SharedBuffer!char a;
    scr.render(g, a);
    SharedBuffer!char b;
    scr.render(g, b); // identical frame → no output
    assert(b[].length == 0, b[]);
}

@("render.screen.scrollEmitsHardwareScroll")
@safe nothrow
unittest
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.tui.cell : CellStyle;
    import std.algorithm.searching : canFind;

    static immutable string[8] labels = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7"];
    Grid g;
    g.resize(6, 8);
    foreach (ushort y; 0 .. 8)
        g.putText(0, y, labels[y], CellStyle.init);

    Screen scr;
    SharedBuffer!char full;
    scr.render(g, full); // first frame — full paint

    // Scroll the whole grid up by 2 and expose two new rows at the bottom.
    g.scrollRect(0, 0, 6, 8, -2, CellStyle.init);
    g.putText(0, 6, "nA", CellStyle.init);
    g.putText(0, 7, "nB", CellStyle.init);

    SharedBuffer!char diff;
    scr.render(g, diff);
    const s = diff[];
    assert(s.canFind("\x1b[1;8r"), s);            // DECSTBM region rows 1..8
    assert(s.canFind("\x1b[2S"), s);              // scroll up by 2 (SU)
    assert(s.canFind("nA") && s.canFind("nB"), s); // only the exposed rows are drawn
    assert(!s.canFind("r2") && !s.canFind("r7"), s); // preserved rows are NOT re-emitted
}

@("render.screen.downwardScrollEmitsIlNotSd")
@safe nothrow
unittest
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.tui.cell : CellStyle;
    import std.algorithm.searching : canFind;

    static immutable string[8] labels = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7"];
    Grid g;
    g.resize(6, 8);
    foreach (ushort y; 0 .. 8)
        g.putText(0, y, labels[y], CellStyle.init);

    Screen scr;
    SharedBuffer!char full;
    scr.render(g, full); // first frame — full paint

    // Scroll the whole grid down by 2 (the viewer scrolling up) and expose
    // two new rows at the top.
    g.scrollRect(0, 0, 6, 8, 2, CellStyle.init);
    g.putText(0, 0, "nA", CellStyle.init);
    g.putText(0, 1, "nB", CellStyle.init);

    SharedBuffer!char diff;
    scr.render(g, diff);
    const s = diff[];
    // Downward must be IL at the region top, NEVER SD (`CSI n T`): zellij
    // silently ignores SD, which desyncs the retained mirror and leaves
    // frozen rows on screen (the scroll-up-under-zellij regression).
    assert(s.canFind("\x1b[1;8r"), s);             // DECSTBM region rows 1..8
    assert(s.canFind("\x1b[1;1H\x1b[2L"), s);      // cursor to region top + IL 2
    assert(!s.canFind("\x1b[2T"), s);              // no SD
    assert(s.canFind("nA") && s.canFind("nB"), s); // only the exposed rows are drawn
    assert(!s.canFind("r2") && !s.canFind("r5"), s); // preserved rows are NOT re-emitted
}
