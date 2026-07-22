// ANSI/SGR → styled-lines bridge for `hue --gui`'s markdown preview.
//
// A fenced ` ```ansi ` block in a doc is literal terminal output (SGR color and
// attribute escapes). In terminal mode hue just prints it and the tty renders
// it; the GPU window has no tty, so this module reproduces that: it drives an
// OFF-SCREEN libghostty-vt terminal — no PTY, no window, no effect callbacks —
// feeds the block through `vt_write`, and reads the resulting cell grid back as
// runs of `AnsiSpan` (already RGB-resolved, with default-colored cells flagged
// so the preview layout can substitute the live theme's page colors).
//
// Deliberately raylib-free (it pulls sparkles:ghostty, not raylib-text): the
// output is neutral RgbColor + attribute bits that gui.d maps onto raylib-text's
// TextStyle at draw time. Compiled by the `gui` and `unittest` configs, excluded
// from the default `application` build (which is both raylib- and ghostty-free).
module gui_ansi;

import sparkles.ghostty;
import sparkles.base.term_color : RgbColor;

/// Neutral text-attribute bits shared by the preview presentation model
/// (`gui_preview.PreviewRun`) and this decoder; gui.d maps them onto
/// `sparkles.raylib_text.TextStyle`.
enum Attr : ubyte
{
    bold          = 1 << 0,
    italic        = 1 << 1,
    underline     = 1 << 2,
    strikethrough = 1 << 3,
}

/// A maximal run of same-styled cells on one line. `fgDefault`/`bgDefault` mark
/// a cell that used the terminal *default* color (SGR 39/49 or never set): the
/// layout substitutes the theme's page fg/bg so ` ```ansi ` blocks stay
/// theme-consistent. `text` is owned (GC) UTF-8.
struct AnsiSpan
{
    string text;
    RgbColor fg;
    RgbColor bg;
    bool fgDefault;
    bool bgDefault;
    ubyte attrs;
}

/// One decoded line: its styled spans, left to right.
struct AnsiLine
{
    AnsiSpan[] spans;
}

/**
Decode `block` (bytes containing SGR escapes) into styled lines by parsing it
with an off-screen libghostty-vt terminal. Cursor-motion / clear sequences are
handled by the VT (they just move the write position); non-SGR escapes never
corrupt output. Returns an empty slice on any allocation/parse failure.

`@system` and GC-allocating — run once at file load, never per frame.
*/
AnsiLine[] decodeAnsi(scope const(char)[] block) @system
{
    if (block.length == 0)
        return null;

    // Grid size: rows = line count, cols = a generous upper bound on visible
    // width (raw byte length over-provisions — extra cells are empty and
    // skipped). A bare LF only indexes down in a VT, so translate LF → CRLF to
    // reset the column, matching the tty's ONLCR that terminal mode relies on.
    size_t rows = 1, curCol = 0, maxCol = 0;
    auto crlf = new char[](0);
    crlf.reserve(block.length + 16);
    foreach (c; block)
    {
        if (c == '\n')
        {
            crlf ~= '\r';
            crlf ~= '\n';
            ++rows;
            if (curCol > maxCol)
                maxCol = curCol;
            curCol = 0;
        }
        else
        {
            crlf ~= c;
            ++curCol;
        }
    }
    if (curCol > maxCol)
        maxCol = curCol;

    enum ushort maxDim = 4000;
    const ushort cols = cast(ushort)(maxCol == 0 ? 1 : (maxCol > maxDim ? maxDim : maxCol));
    const ushort rowN = cast(ushort)(rows > maxDim ? maxDim : rows);

    GhosttyTerminal term;
    GhosttyTerminalOptions opts = {cols: cols, rows: rowN, max_scrollback: 0};
    if (ghostty_terminal_new(null, &term, opts) != GHOSTTY_SUCCESS)
        return null;
    scope (exit) ghostty_terminal_free(term);
    ghostty_terminal_vt_write(term, cast(const(ubyte)*) crlf.ptr, crlf.length);

    GhosttyRenderState rs;
    if (ghostty_render_state_new(null, &rs) != GHOSTTY_SUCCESS)
        return null;
    scope (exit) ghostty_render_state_free(rs);
    ghostty_render_state_update(rs, term);

    GhosttyRenderStateRowIterator rowIter;
    if (ghostty_render_state_row_iterator_new(null, &rowIter) != GHOSTTY_SUCCESS)
        return null;
    scope (exit) ghostty_render_state_row_iterator_free(rowIter);

    GhosttyRenderStateRowCells cells;
    if (ghostty_render_state_row_cells_new(null, &cells) != GHOSTTY_SUCCESS)
        return null;
    scope (exit) ghostty_render_state_row_cells_free(cells);

    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIter);

    AnsiLine[] lines;
    while (ghostty_render_state_row_iterator_next(rowIter))
    {
        ghostty_render_state_row_get(rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells);

        AnsiSpan[] spans;
        AnsiSpan cur;
        bool have;
        while (ghostty_render_state_row_cells_next(cells))
        {
            uint glen;
            ghostty_render_state_row_cells_get(cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);
            if (glen == 0)
                continue; // empty padding cell (no glyph)

            uint[16] cps;
            ghostty_render_state_row_cells_get(cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, cps.ptr);

            GhosttyColorRgb fgr = {r: 255, g: 255, b: 255};
            GhosttyColorRgb bgr;
            const bgOk = ghostty_render_state_row_cells_get(cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bgr) == GHOSTTY_SUCCESS;
            ghostty_render_state_row_cells_get(cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fgr);

            GhosttyStyle st;
            st.size = GhosttyStyle.sizeof;
            ghostty_render_state_row_cells_get(cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &st);

            RgbColor fg = RgbColor(fgr.r, fgr.g, fgr.b);
            RgbColor bg = RgbColor(bgr.r, bgr.g, bgr.b);
            bool fgDef = st.fg_color.tag == GHOSTTY_STYLE_COLOR_NONE;
            bool bgDef = !bgOk || st.bg_color.tag == GHOSTTY_STYLE_COLOR_NONE;
            if (st.inverse)
            {
                auto tc = fg; fg = bg; bg = tc;
                auto td = fgDef; fgDef = bgDef; bgDef = td;
            }

            ubyte attrs;
            if (st.bold) attrs |= Attr.bold;
            if (st.italic) attrs |= Attr.italic;
            if (st.underline != 0) attrs |= Attr.underline;
            if (st.strikethrough) attrs |= Attr.strikethrough;

            const cell = encodeCell(cps[0 .. glen < 16 ? glen : 16]);

            if (have && cur.fg == fg && cur.bg == bg && cur.fgDefault == fgDef
                && cur.bgDefault == bgDef && cur.attrs == attrs)
                cur.text ~= cell;
            else
            {
                if (have)
                    spans ~= cur;
                cur = AnsiSpan(cell, fg, bg, fgDef, bgDef, attrs);
                have = true;
            }
        }
        if (have)
            spans ~= cur;
        lines ~= AnsiLine(spans);
    }

    // Drop trailing blank lines the fixed grid pads with.
    while (lines.length && lines[$ - 1].spans.length == 0)
        lines = lines[0 .. $ - 1];
    return lines;
}

/// UTF-8 for a grapheme cluster's codepoints (invalid ones become U+FFFD).
private string encodeCell(scope const(uint)[] cps) @system
{
    import std.utf : encode, isValidDchar;

    char[] out_;
    foreach (cp; cps)
    {
        char[4] e;
        const d = isValidDchar(cp) ? cast(dchar) cp : '�';
        out_ ~= e[0 .. encode(e, d)];
    }
    return cast(string) out_;
}

// The full text of a decoded line (spans concatenated).
version (unittest) private string lineText(in AnsiLine l) @safe
{
    string s;
    foreach (sp; l.spans)
        s ~= sp.text;
    return s;
}

@("gui_ansi.decode.colorsAndReset")
@system
unittest
{
    // "Error: " red, then default; SGR 39 resets fg to default.
    auto lines = decodeAnsi("\x1b[31mError:\x1b[39m ok");
    assert(lines.length == 1);
    assert(lineText(lines[0]) == "Error: ok");

    // the first span is the red "Error:" (explicit, non-default fg)
    auto first = lines[0].spans[0];
    assert(first.text == "Error:");
    assert(!first.fgDefault);
    assert(first.fg != RgbColor(0, 0, 0));

    // a later span is default-colored (the reset)
    import std.algorithm.searching : any;
    assert(lines[0].spans.any!(sp => sp.fgDefault));
}

@("gui_ansi.decode.attributes")
@system
unittest
{
    auto lines = decodeAnsi("\x1b[1mB\x1b[0m\x1b[3mI\x1b[0m\x1b[4mU\x1b[0m");
    assert(lines.length == 1);
    ubyte seen;
    foreach (sp; lines[0].spans)
        seen |= sp.attrs;
    assert(seen & Attr.bold);
    assert(seen & Attr.italic);
    assert(seen & Attr.underline);
}

@("gui_ansi.decode.truecolor")
@system
unittest
{
    auto lines = decodeAnsi("\x1b[38;2;10;20;30mX");
    assert(lines.length == 1);
    assert(lines[0].spans[0].fg == RgbColor(10, 20, 30));
    assert(!lines[0].spans[0].fgDefault);
}

@("gui_ansi.decode.multiline")
@system
unittest
{
    auto lines = decodeAnsi("\x1b[31mred\x1b[0m\ngreen\nblue");
    assert(lines.length == 3);
    assert(lineText(lines[0]) == "red");
    assert(lineText(lines[1]) == "green");
    assert(lineText(lines[2]) == "blue");
}

@("gui_ansi.decode.plainDefault")
@system
unittest
{
    auto lines = decodeAnsi("plain text");
    assert(lines.length == 1);
    assert(lineText(lines[0]) == "plain text");
    foreach (sp; lines[0].spans)
        assert(sp.fgDefault); // no SGR ⇒ default fg throughout
}

@("gui_ansi.decode.empty")
@system
unittest
{
    assert(decodeAnsi("").length == 0);
}
