/**
The VT screen through a `sparkles:ui` canvas (`TVW7`, the terminal arm): the
same render-state walk as the raylib per-cell renderer, emitted as cell-space
canvas ops — so an embedded pane paints wherever `isCanvas` reaches, a
terminal grid and the test recorder alike, with no fonts and no window.

What this deliberately does $(B not) carry over from the pixel renderer:
kitty images (nothing cell-shaped to paint them with), the scrollbar and the
exit banner (the embedder's chrome owns those affordances), and multi-
codepoint grapheme clusters (a cell op carries one `dchar`; the base
codepoint paints, combining marks and ZWJ sequences drop — an open issue).

Call it after `decideRedraw` snapshotted the render state; like `paintFrame`
it clears the per-row and global dirty flags, being the frame's painter.
*/
module sparkles.terminal_view.cell_paint;

import sparkles.base.term_color : RgbColor;
import sparkles.base.term_style : TextAttr, UnderlineStyle;
import sparkles.ghostty.c;
import sparkles.terminal_view.core : CoreState, resolveCell;
import sparkles.ui.canvas : isCanvas;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.style : Visual;

/// Paints the terminal's viewport into `c`, cell-for-cell, at `pane`'s
/// offset and clipped to its extent (the grid may lag the pane's size by a
/// frame — the ground fill covers the difference in the terminal's default
/// background). The cursor renders as an inverse block.
void paintCells(Canvas)(ref CoreState s, ref Canvas c, in Rect pane)
if (isCanvas!Canvas)
{
    GhosttyRenderStateColors colors;
    colors.size = GhosttyRenderStateColors.sizeof;
    ghostty_render_state_colors_get(s.render_state, &colors);

    const defaultBg = rgbOf(colors.background);
    c.fillRect(pane, Visual(fg: rgbOf(colors.foreground), bg: defaultBg,
        hasBg: true));

    // The cursor's viewport cell, painted inverse inside the pass below.
    bool cursorVisible = false, cursorInViewport = false;
    ghostty_render_state_get(s.render_state,
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, cast(void*) &cursorVisible);
    ghostty_render_state_get(s.render_state,
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, cast(void*) &cursorInViewport);
    int curX = -1, curY = -1;
    if (cursorVisible && cursorInViewport)
    {
        ushort cx = 0, cy = 0;
        ghostty_render_state_get(s.render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, cast(void*) &cx);
        ghostty_render_state_get(s.render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, cast(void*) &cy);
        curX = cx;
        curY = cy;
    }

    ghostty_render_state_get(s.render_state,
        GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &s.row_iter);
    int gy = 0;
    while (ghostty_render_state_row_iterator_next(s.row_iter))
    {
        ghostty_render_state_row_get(s.row_iter,
            GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &s.cells);

        int gx = 0;
        while (ghostty_render_state_row_cells_next(s.cells))
        {
            // Beyond the pane (the one-frame resize lag): consume the cell,
            // paint nothing.
            if (gx >= pane.width || gy >= pane.height)
            {
                gx++;
                continue;
            }

            // No selection and no hover in an embedded pane (mouse routing
            // waits on the mouse-event conversion), so those inputs are
            // inert here; reverse video still resolves.
            const rc = resolveCell(s.cells, colors, gx, gy, false,
                GhosttyPointCoordinate.init, GhosttyPointCoordinate.init,
                s.selState, s.hoverState);

            RgbColor fg = rc.hasGrapheme ? rgbOf3(rc.fgCol) : rgbOf(colors.foreground);
            RgbColor bg = rc.hasBg ? rgbOf3(rc.bgCol) : defaultBg;
            bool hasBg = rc.hasBg;
            if (gx == curX && gy == curY)
            {
                // The inverse block: glyph in the ground color over a
                // foreground-colored cell.
                const t = fg;
                fg = bg;
                bg = t;
                hasBg = true;
            }

            const p = Point(pane.x + gx, pane.y + gy);
            const v = Visual(fg: fg, bg: bg, hasBg: hasBg,
                styleBits: styleBitsOf(rc.style),
                underline: underlineOf(rc.style));
            if (hasBg)
                c.fillRect(Rect(p.x, p.y, 1, 1), v);
            if (rc.hasGrapheme)
                c.glyph(p, cast(dchar) rc.codepoints[0], v);

            gx++;
        }

        // Clear this row's dirty flag now that it has been drawn.
        bool rowClean = false;
        ghostty_render_state_row_set(s.row_iter,
            GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &rowClean);
        gy++;
    }

    // Reset global dirty state so the next update reports changes accurately.
    GhosttyRenderStateDirty cleanState = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_set(s.render_state,
        GHOSTTY_RENDER_STATE_OPTION_DIRTY, &cleanState);
}

private RgbColor rgbOf(in GhosttyColorRgb c) @safe pure nothrow @nogc
    => RgbColor(c.r, c.g, c.b);

// raylib's Color, without naming the type (keeps this module raylib-free in
// spirit — only `ResolvedCell` carries it across).
private RgbColor rgbOf3(C)(in C c) => RgbColor(c.r, c.g, c.b);

private ushort styleBitsOf(in GhosttyStyle st) @safe pure nothrow @nogc
{
    TextAttr a;
    if (st.bold)
        a = a | TextAttr.bold;
    if (st.italic)
        a = a | TextAttr.italic;
    if (st.strikethrough)
        a = a | TextAttr.strikethrough;
    // `inverse` is NOT forwarded: resolveCell already swapped the colors,
    // and a painter honoring the bit would swap them back.
    return a.bits;
}

/// Ghostty's underline numbering is SGR 4:x — the same values
/// $(REF UnderlineStyle, sparkles,base,term_style) uses.
private UnderlineStyle underlineOf(in GhosttyStyle st) @safe pure nothrow @nogc
    => st.underline <= UnderlineStyle.max
        ? cast(UnderlineStyle) st.underline : UnderlineStyle.single;

// ---------------------------------------------------------------------------

@("terminal_view.cell_paint.styledBytesLandOnTheCanvas")
@system
unittest
{
    import sparkles.ui.canvas : OpKind, RecordingCanvas;

    // Headless end to end: a bare terminal (no pty, no fonts, no window),
    // fed styled bytes through vt_write, painted onto the recording canvas —
    // the terminal-arm pane's whole pipeline.
    CoreState s;
    GhosttyTerminalOptions topts = { cols: 10, rows: 3 };
    ghostty_terminal_new(null, &s.terminal, topts);
    assert(s.terminal !is null);
    scope (exit) ghostty_terminal_free(s.terminal);
    ghostty_render_state_new(null, &s.render_state);
    scope (exit) ghostty_render_state_free(s.render_state);
    ghostty_render_state_row_iterator_new(null, &s.row_iter);
    scope (exit) ghostty_render_state_row_iterator_free(s.row_iter);
    ghostty_render_state_row_cells_new(null, &s.cells);
    scope (exit) ghostty_render_state_row_cells_free(s.cells);
    s.cols = 10;
    s.rows = 3;

    static immutable bytes = "A\x1b[1;31mB\x1b[0m";
    ghostty_terminal_vt_write(s.terminal,
        cast(const(ubyte)*) bytes.ptr, cast(uint) bytes.length);
    ghostty_render_state_update(s.render_state, s.terminal);

    RecordingCanvas c;
    const pane = Rect(2, 1, 10, 3);
    paintCells(s, c, pane);

    // The ground fill covers the pane first.
    assert(c.ops.length > 0);
    assert(c.ops[0].kind == OpKind.fillRect && c.ops[0].rect == pane);

    // 'A' plain at the pane origin; 'B' beside it, bold, its own red.
    const(typeof(c.ops[0]))* opA, opB;
    foreach (ref op; c.ops)
    {
        if (op.kind != OpKind.glyph)
            continue;
        if (op.glyph == 'A')
            opA = &op;
        if (op.glyph == 'B')
            opB = &op;
    }
    assert(opA !is null && opB !is null);
    assert(opA.rect.x == pane.x && opA.rect.y == pane.y);
    assert(opB.rect.x == pane.x + 1 && opB.rect.y == pane.y);
    assert(TextAttr(cast(ubyte) opB.visual.styleBits).has(TextAttr.bold));
    assert(!TextAttr(cast(ubyte) opA.visual.styleBits).has(TextAttr.bold));
    assert(opA.visual.fg != opB.visual.fg, "SGR 31 must resolve to its own red");

    // The cursor sits after 'B' as an inverse block: a 1×1 fill at its cell.
    bool cursorBlock;
    foreach (ref op; c.ops)
        if (op.kind == OpKind.fillRect && op.rect == Rect(pane.x + 2, pane.y, 1, 1)
            && op.visual.hasBg)
            cursorBlock = true;
    assert(cursorBlock, "the cursor cell paints an inverse block");
}
