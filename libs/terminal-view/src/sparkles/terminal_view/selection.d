/**
The selection model (docs/specs/terminal/selection.md `TSE1`, `TSE2`): a
pair of tracked grid points — the $(I start), where the selection began, and
the $(I end), the point that moves — in screen-plus-scrollback coordinates,
a shape (stream or block), and the operations every input path shares:
select at a point with a granularity, move either end, select all, clear,
read the text.

The desktop's polled mouse (`input.handle_mouse`) and the touch embedder
(`TerminalView.selectAt` and friends) both drive these functions over one
`SelectionState`; neither owns the model, so the same two ends give the same
text whichever path set them.

$(B Word boundaries) (`TSE1`) are the terminal's, not libghostty's: runs of
letters, digits and `_-./~:@%+`, so a path or a URL is one word — decided by
the pure $(LREF wordSpan) and $(LREF urlSpan) over one row's cells.
*/
module sparkles.terminal_view.selection;

import sparkles.ghostty.c;
import sparkles.terminal_view.input : SelectionState;

/// How much a select-at takes (`TSE2`).
enum Granularity : ubyte
{
    character, /// the cell under the point
    word, /// the word under the point — a URL as a whole when inside one (`TSE1`)
    url, /// the URL under the point, else nothing
    line, /// the row under the point, trailing blanks trimmed
}

/// The selection's two ends: where it began and the one that moves.
enum SelectionEnd : ubyte
{
    start, /// where the selection began (the anchor)
    end, /// the moving end (the head)
}

/**
The selection's extent in the viewport's cells, ends in reading order. A row
outside `0 .. rows` is scrolled out of view (negative: above it), so a handle
that is not on screen is not drawn.
*/
struct SelectionBounds
{
    /// Whether there is a selection.
    bool any;
    /// A block selection (the ends are opposite corners).
    bool rectangular;
    /// The first cell in reading order (top-left for a block).
    int firstCol, firstRow;
    /// The last cell in reading order (bottom-right for a block), inclusive.
    int lastCol, lastRow;
    /// Which tracked end the first cell is — what a handle drawn there moves.
    SelectionEnd firstEnd;

    /// The tracked end at the last cell.
    SelectionEnd lastEnd() const @safe pure nothrow @nogc
        => firstEnd == SelectionEnd.start ? SelectionEnd.end : SelectionEnd.start;
}

// ─────────────────────────────────────────────────────────────────────────────
// The pure half: boundaries within one row.
// ─────────────────────────────────────────────────────────────────────────────

/**
Whether `c` belongs to a word (`TSE1`): a letter, a digit, or one of
`_-./~:@%+` — the characters that keep a path, a URL or an address whole.
*/
bool isWordChar(dchar c) @safe pure nothrow @nogc
{
    import std.uni : isAlpha, isNumber;

    switch (c)
    {
        case '_', '-', '.', '/', '~', ':', '@', '%', '+':
            return true;
        default:
            return c > 0x7f ? isAlpha(c) || isNumber(c)
                : (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
    }
}

/**
The word covering column `col` of `row` — one code point per cell, a wide
character repeated in its second cell, a blank cell `' '` — as the inclusive
columns `lo` .. `hi`; `false` when the cell is no word character.
*/
bool wordSpan(scope const(dchar)[] row, size_t col, out size_t lo, out size_t hi)
    @safe pure nothrow @nogc
{
    if (col >= row.length || !isWordChar(row[col]))
        return false;
    lo = hi = col;
    while (lo > 0 && isWordChar(row[lo - 1]))
        lo--;
    while (hi + 1 < row.length && isWordChar(row[hi + 1]))
        hi++;
    return true;
}

///
@("selection.wordSpan.pathsAndUrlsAreOneWord")
@safe pure nothrow @nogc unittest
{
    static immutable dchar[] row = "cd ~/code/repos-mine/x_y.d && ls"d;
    size_t lo, hi;
    assert(wordSpan(row, 8, lo, hi));
    assert(row[lo .. hi + 1] == "~/code/repos-mine/x_y.d"d);
    assert(!wordSpan(row, 2, lo, hi), "a blank is no word");
    assert(!wordSpan(row, 28, lo, hi), "& is no word character");
    assert(wordSpan(row, 0, lo, hi) && lo == 0 && hi == 1);
    static immutable dchar[] mail = "to: petar@example.org, 100%+1"d;
    assert(wordSpan(mail, 6, lo, hi) && mail[lo .. hi + 1] == "petar@example.org"d);
    assert(wordSpan(mail, 26, lo, hi) && mail[lo .. hi + 1] == "100%+1"d);
    static immutable dchar[] wide = "名前 ok"d;
    assert(wordSpan(wide, 1, lo, hi) && lo == 0 && hi == 1, "letters of any script");
}

/// Whether a URL scheme the terminal recognises starts at `at`.
private bool schemeAt(scope const(dchar)[] row, size_t at) @safe pure nothrow @nogc
{
    static immutable dstring[] schemes = ["https://", "http://", "mailto:", "ftp://", "file://"];
    foreach (s; schemes)
        if (row.length - at >= s.length && row[at .. at + s.length] == s)
            return at == 0 || !isSchemeChar(row[at - 1]);
    return false;
}

private bool isSchemeChar(dchar c) @safe pure nothrow @nogc
    => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');

/// A cell that ends a URL: a blank, a quote, an angle bracket or a control.
private bool endsUrl(dchar c) @safe pure nothrow @nogc
    => c <= ' ' || c == '"' || c == '\'' || c == '<' || c == '>' || c == '`' || c == 0x7f;

/**
The URL covering column `col` of `row` (cells as for $(LREF wordSpan)): a run
of non-blank cells from a scheme (`http://`, `https://`, `mailto:`, `ftp://`,
`file://`), its trailing sentence punctuation dropped and a closing
parenthesis kept only when the URL opened one. `false` when no URL covers
the column.
*/
bool urlSpan(scope const(dchar)[] row, size_t col, out size_t lo, out size_t hi)
    @safe pure nothrow @nogc
{
    if (col >= row.length)
        return false;
    // Back to the start of the run of non-blank cells, then every scheme in
    // it up to the column: the last one that starts at or before it.
    size_t runLo = col;
    while (runLo > 0 && !endsUrl(row[runLo - 1]))
        runLo--;
    bool found;
    size_t start;
    foreach (i; runLo .. col + 1)
        if (schemeAt(row, i))
        {
            found = true;
            start = i;
        }
    if (!found || endsUrl(row[col]))
        return false;
    size_t end = start;
    while (end + 1 < row.length && !endsUrl(row[end + 1]))
        end++;
    // Trailing punctuation belongs to the sentence, not the URL.
    while (end > start)
    {
        const c = row[end];
        if (c == '.' || c == ',' || c == ';' || c == ':' || c == '!' || c == '?')
            end--;
        else if (c == ')' && !opensParen(row[start .. end]))
            end--;
        else
            break;
    }
    if (col > end)
        return false;
    lo = start;
    hi = end;
    return true;
}

private bool opensParen(scope const(dchar)[] s) @safe pure nothrow @nogc
{
    int depth;
    foreach (c; s)
        depth += c == '(' ? 1 : c == ')' ? -1 : 0;
    return depth > 0;
}

///
@("selection.urlSpan.wholeUrlWithoutTrailingPunctuation")
@safe pure nothrow @nogc unittest
{
    static immutable dchar[] row = "See https://ex.org/a?b=1&c=(2). Done"d;
    size_t lo, hi;
    assert(urlSpan(row, 10, lo, hi));
    assert(row[lo .. hi + 1] == "https://ex.org/a?b=1&c=(2)"d, "the query and a balanced paren kept");
    assert(!urlSpan(row, 1, lo, hi), "outside the URL");
    assert(!urlSpan(row, 31, lo, hi), "the full stop is the sentence's");
    static immutable dchar[] paren = "(see http://a.b/c)"d;
    assert(urlSpan(paren, 6, lo, hi) && paren[lo .. hi + 1] == "http://a.b/c"d);
    static immutable dchar[] mail = "mailto:petar@example.org,"d;
    assert(urlSpan(mail, 0, lo, hi) && mail[lo .. hi + 1] == "mailto:petar@example.org"d);
    static immutable dchar[] none = "nothttp://x"d;
    assert(!urlSpan(none, 5, lo, hi), "a scheme glued to a word is not one");
}

/**
The span a select-at takes in `row` at `col` for `g`; `false` when it takes
nothing (a blank, or no URL there for `Granularity.url`). A line is the row
up to its last non-blank cell.
*/
bool spanAt(scope const(dchar)[] row, size_t col, Granularity g, out size_t lo, out size_t hi)
    @safe pure nothrow @nogc
{
    final switch (g)
    {
        case Granularity.character:
            if (col >= row.length)
                return false;
            lo = hi = col;
            return true;
        case Granularity.word:
            return urlSpan(row, col, lo, hi) || wordSpan(row, col, lo, hi);
        case Granularity.url:
            return urlSpan(row, col, lo, hi);
        case Granularity.line:
            size_t last = row.length;
            while (last > 0 && row[last - 1] == ' ')
                last--;
            if (last == 0)
                return false;
            lo = 0;
            hi = last - 1;
            return true;
    }
}

///
@("selection.spanAt.granularities")
@safe pure nothrow @nogc unittest
{
    static immutable dchar[] row = "open https://a.b/c now   "d;
    size_t lo, hi;
    assert(spanAt(row, 8, Granularity.word, lo, hi) && row[lo .. hi + 1] == "https://a.b/c"d);
    assert(spanAt(row, 1, Granularity.word, lo, hi) && row[lo .. hi + 1] == "open"d);
    assert(!spanAt(row, 1, Granularity.url, lo, hi));
    assert(spanAt(row, 2, Granularity.line, lo, hi) && lo == 0 && row[hi] == 'w');
    assert(spanAt(row, 4, Granularity.character, lo, hi) && lo == 4 && hi == 4);
    static immutable dchar[] blank = "    "d;
    assert(!spanAt(blank, 1, Granularity.line, lo, hi));
}

// ─────────────────────────────────────────────────────────────────────────────
// The terminal half.
// ─────────────────────────────────────────────────────────────────────────────

private GhosttyPoint pointOf(GhosttyPointTag tag, int x, uint y) @safe pure nothrow @nogc
{
    GhosttyPoint p;
    p.tag = tag;
    p.value.coordinate.x = cast(ushort)(x < 0 ? 0 : x);
    p.value.coordinate.y = y;
    return p;
}

/**
Reads viewport row `y` into `cells` — one code point per cell, a wide
character's second cell repeating it, a blank `' '` — and returns the filled
prefix (empty when the row does not exist).
*/
dchar[] readViewportRow(GhosttyTerminal t, int y, return scope dchar[] cells) @system nothrow @nogc
{
    if (y < 0)
        return cells[0 .. 0];
    size_t n;
    foreach (x; 0 .. cells.length)
    {
        GhosttyGridRef r;
        r.size = GhosttyGridRef.sizeof;
        if (ghostty_terminal_grid_ref(t, pointOf(GHOSTTY_POINT_TAG_VIEWPORT, cast(int) x, y), &r)
            != GHOSTTY_SUCCESS)
            break;
        GhosttyCell cell;
        GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
        if (ghostty_grid_ref_cell(&r, &cell) == GHOSTTY_SUCCESS)
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
        if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL && n > 0)
        {
            cells[n] = cells[n - 1];
            n++;
            continue;
        }
        uint[4] cps;
        size_t len;
        const res = ghostty_grid_ref_graphemes(&r, cps.ptr, cps.length, &len);
        cells[n++] = (res == GHOSTTY_SUCCESS || res == GHOSTTY_OUT_OF_SPACE) && len > 0
            && cps[0] > ' ' ? cast(dchar) cps[0] : ' ';
    }
    return cells[0 .. n];
}

/// Points both ends at viewport cells (`x0`, `y0`) and (`x1`, `y1`), replacing
/// any selection; false when a point is outside the viewport.
bool selectCells(GhosttyTerminal t, ref SelectionState sel, int x0, int y0, int x1, int y1,
    bool rectangular = false) @system nothrow @nogc
{
    sel.free();
    if (y0 < 0 || y1 < 0)
        return false;
    if (ghostty_terminal_grid_ref_track(t, pointOf(GHOSTTY_POINT_TAG_VIEWPORT, x0, y0), &sel.start)
            != GHOSTTY_SUCCESS
        || ghostty_terminal_grid_ref_track(t, pointOf(GHOSTTY_POINT_TAG_VIEWPORT, x1, y1), &sel.end)
            != GHOSTTY_SUCCESS)
    {
        sel.free();
        return false;
    }
    sel.isRectangular = rectangular;
    return true;
}

/**
Selects at viewport cell (`x`, `y`) with granularity `g` (`TSE1`, `TSE2`);
false, with the selection cleared, when that takes nothing (a blank cell).
*/
bool selectAt(GhosttyTerminal t, ref SelectionState sel, int x, int y, ushort cols, Granularity g) @system nothrow @nogc
{
    dchar[512] buf = void;
    const row = readViewportRow(t, y, buf[0 .. cols < buf.length ? cols : buf.length]);
    size_t lo, hi;
    if (x < 0 || !spanAt(row, cast(size_t) x, g, lo, hi))
    {
        sel.free();
        return false;
    }
    // A word or a URL soft-wrapped across rows is one (`TSE1`): follow the
    // wraps both ways.
    int y0 = y, y1 = y, x0 = cast(int) lo, x1 = cast(int) hi;
    if (g == Granularity.word || g == Granularity.url)
    {
        const url = g == Granularity.url || !isWordChar(row[x]) || !wordSpanIs(row, lo, hi);
        size_t lastLen = row.length;
        // A URL's trailing punctuation was trimmed; at a wrap it is the URL's.
        if (url && rowWraps(t, y1))
        {
            size_t e = hi + 1;
            while (e < row.length && !endsUrl(row[e]))
                e++;
            if (e == row.length)
                x1 = cast(int) row.length - 1;
        }
        foreach (_; 0 .. 16)
        {
            if (x1 + 1 != lastLen || !rowWraps(t, y1))
                break;
            dchar[512] nb = void;
            const next = readViewportRow(t, y1 + 1, nb[0 .. row.length]);
            size_t n;
            while (n < next.length && (url ? !endsUrl(next[n]) : isWordChar(next[n])))
                n++;
            if (n == 0)
                break;
            y1++;
            x1 = cast(int) n - 1;
            lastLen = next.length;
        }
        foreach (_; 0 .. 16)
        {
            if (x0 != 0 || y0 == 0 || !rowWraps(t, y0 - 1))
                break;
            dchar[512] pb = void;
            const prev = readViewportRow(t, y0 - 1, pb[0 .. row.length]);
            size_t n = prev.length;
            while (n > 0 && (url ? !endsUrl(prev[n - 1]) : isWordChar(prev[n - 1])))
                n--;
            if (n == prev.length)
                break;
            y0--;
            x0 = cast(int) n;
        }
        if (url && y1 > y)
        {
            dchar[512] lb = void;
            const last = readViewportRow(t, y1, lb[0 .. row.length]);
            while (x1 > 0 && x1 < last.length && isTrailingPunct(last[x1]))
                x1--;
        }
    }
    return selectCells(t, sel, x0, y0, x1, y1);
}

private bool isTrailingPunct(dchar c) @safe pure nothrow @nogc
    => c == '.' || c == ',' || c == ';' || c == ':' || c == '!' || c == '?';

// Whether `row[lo .. hi]` is exactly the word there (not a URL `spanAt` took).
private bool wordSpanIs(scope const(dchar)[] row, size_t lo, size_t hi) @safe pure nothrow @nogc
{
    size_t a, b;
    return wordSpan(row, lo, a, b) && a == lo && b == hi;
}

// Whether viewport row `y` soft-wraps into the next.
private bool rowWraps(GhosttyTerminal t, int y) @system nothrow @nogc
{
    GhosttyGridRef r;
    r.size = GhosttyGridRef.sizeof;
    if (y < 0 || ghostty_terminal_grid_ref(t, pointOf(GHOSTTY_POINT_TAG_VIEWPORT, 0, y), &r) != GHOSTTY_SUCCESS)
        return false;
    GhosttyRow gr;
    bool wraps;
    return ghostty_grid_ref_row(&r, &gr) == GHOSTTY_SUCCESS
        && ghostty_row_get(gr, GHOSTTY_ROW_DATA_WRAP, &wraps) == GHOSTTY_SUCCESS && wraps;
}

/// Moves end `which` to viewport cell (`x`, `y`); the ends may cross. False
/// without a selection or outside the viewport.
bool moveEnd(GhosttyTerminal t, ref SelectionState sel, SelectionEnd which, int x, int y) @system nothrow @nogc
{
    auto r = which == SelectionEnd.start ? sel.start : sel.end;
    if (r is null || y < 0)
        return false;
    return ghostty_tracked_grid_ref_set(r, t, pointOf(GHOSTTY_POINT_TAG_VIEWPORT, x, y))
        == GHOSTTY_SUCCESS;
}

/// Selects everything the terminal holds — scrollback and screen; false when
/// it holds nothing.
bool selectAll(GhosttyTerminal t, ref SelectionState sel) @system nothrow @nogc
{
    GhosttySelection all;
    all.size = GhosttySelection.sizeof;
    if (ghostty_terminal_select_all(t, &all) != GHOSTTY_SUCCESS)
        return false;
    GhosttyPointCoordinate a, b;
    if (ghostty_terminal_point_from_grid_ref(t, &all.start, GHOSTTY_POINT_TAG_SCREEN, &a) != GHOSTTY_SUCCESS
        || ghostty_terminal_point_from_grid_ref(t, &all.end, GHOSTTY_POINT_TAG_SCREEN, &b) != GHOSTTY_SUCCESS)
        return false;
    sel.free();
    if (ghostty_terminal_grid_ref_track(t, pointOf(GHOSTTY_POINT_TAG_SCREEN, a.x, a.y), &sel.start)
            != GHOSTTY_SUCCESS
        || ghostty_terminal_grid_ref_track(t, pointOf(GHOSTTY_POINT_TAG_SCREEN, b.x, b.y), &sel.end)
            != GHOSTTY_SUCCESS)
    {
        sel.free();
        return false;
    }
    return true;
}

/// Whether `sel` still selects something: both ends exist and still point
/// into the terminal (clearing the scrollback can take their rows away).
bool selectionLive(in SelectionState sel) @system nothrow @nogc
    => sel.start !is null && sel.end !is null
        && ghostty_tracked_grid_ref_has_value(cast(GhosttyTrackedGridRef) sel.start)
        && ghostty_tracked_grid_ref_has_value(cast(GhosttyTrackedGridRef) sel.end);

/// The selection's extent in viewport cells (`any` false without one).
SelectionBounds bounds(GhosttyTerminal t, in SelectionState sel) @system nothrow @nogc
{
    SelectionBounds b;
    if (!selectionLive(sel))
        return b;
    GhosttyPointCoordinate s, e;
    if (ghostty_tracked_grid_ref_point(cast(GhosttyTrackedGridRef) sel.start,
            GHOSTTY_POINT_TAG_SCREEN, &s) != GHOSTTY_SUCCESS
        || ghostty_tracked_grid_ref_point(cast(GhosttyTrackedGridRef) sel.end,
            GHOSTTY_POINT_TAG_SCREEN, &e) != GHOSTTY_SUCCESS)
        return b;
    GhosttyTerminalScrollbar sb;
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, cast(void*) &sb);
    const top = cast(long) sb.offset;
    b.any = true;
    b.rectangular = sel.isRectangular;
    const startFirst = s.y < e.y || (s.y == e.y && s.x <= e.x);
    b.firstEnd = startFirst ? SelectionEnd.start : SelectionEnd.end;
    const f = startFirst ? s : e, l = startFirst ? e : s;
    b.firstRow = cast(int)(f.y - top);
    b.lastRow = cast(int)(l.y - top);
    if (sel.isRectangular)
    {
        b.firstCol = s.x < e.x ? s.x : e.x;
        b.lastCol = s.x < e.x ? e.x : s.x;
    }
    else
    {
        b.firstCol = f.x;
        b.lastCol = l.x;
    }
    return b;
}

/**
The selection as plain text (`TSE2`): a stream's soft-wrapped rows joined
without a newline, a block's rows joined by `\n`, trailing blanks trimmed.
Handed to `sink` borrowed; false without a selection.
*/
bool withSelectionText(Sink)(GhosttyTerminal t, in SelectionState sel, scope Sink sink)
{
    if (!selectionLive(sel))
        return false;
    GhosttySelection snap;
    snap.size = GhosttySelection.sizeof;
    snap.start.size = GhosttyGridRef.sizeof;
    snap.end.size = GhosttyGridRef.sizeof;
    if (ghostty_tracked_grid_ref_snapshot(cast(GhosttyTrackedGridRef) sel.start, &snap.start)
            != GHOSTTY_SUCCESS
        || ghostty_tracked_grid_ref_snapshot(cast(GhosttyTrackedGridRef) sel.end, &snap.end)
            != GHOSTTY_SUCCESS)
        return false;
    snap.rectangle = sel.isRectangular;

    GhosttyTerminalSelectionFormatOptions o;
    o.size = GhosttyTerminalSelectionFormatOptions.sizeof;
    o.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    o.unwrap = !sel.isRectangular;
    o.trim = true;
    o.selection = &snap;
    ubyte* p;
    size_t n;
    if (ghostty_terminal_selection_format_alloc(t, null, o, &p, &n) != GHOSTTY_SUCCESS)
        return false;
    scope (exit) ghostty_free(null, p, n);
    sink(cast(const(char)[]) p[0 .. n]);
    return true;
}

/**
The OSC 8 hyperlinks under the selection's visible cells, distinct, at most
`into.length` of them, written to `into` as owned (GC) strings; returns how
many distinct ones there were (which may exceed `into.length`).
*/
size_t selectionHyperlinks(GhosttyTerminal t, in SelectionState sel, ushort cols, ushort rows,
    string[] into) @system nothrow
{
    const b = bounds(t, sel);
    if (!b.any)
        return 0;
    size_t found;
    char[2048] buf = void;
    const y0 = b.firstRow < 0 ? 0 : b.firstRow;
    const y1 = b.lastRow >= rows ? rows - 1 : b.lastRow;
    foreach (y; y0 .. y1 + 1)
    {
        const x0 = b.rectangular || y == b.firstRow ? b.firstCol : 0;
        const x1 = b.rectangular || y == b.lastRow ? b.lastCol : cols - 1;
        foreach (x; x0 .. x1 + 1)
        {
            GhosttyGridRef r;
            r.size = GhosttyGridRef.sizeof;
            if (ghostty_terminal_grid_ref(t, pointOf(GHOSTTY_POINT_TAG_VIEWPORT, x, y), &r)
                != GHOSTTY_SUCCESS)
                continue;
            size_t n;
            if (ghostty_grid_ref_hyperlink_uri(&r, cast(ubyte*) buf.ptr, buf.length, &n)
                != GHOSTTY_SUCCESS || n == 0)
                continue;
            const uri = buf[0 .. n];
            bool seen;
            foreach (s; into[0 .. found < into.length ? found : into.length])
                seen |= s == uri;
            if (seen)
                continue;
            if (found < into.length)
                into[found] = uri.idup;
            found++;
        }
    }
    return found;
}

/**
Whether the program cleared the selection's text away (`TSE4`): an end lost
its row, its rows were cleared from the scrollback (libghostty then moves
both ends to the first cell left), or nothing but blanks is left under it
(the screen was erased: the rows stay, blanked). Cheap while
either end is on text; the text is read only when both ends are blank.
*/
bool selectionEmptied(GhosttyTerminal t, in SelectionState sel) @system nothrow @nogc
{
    if (!selectionLive(sel))
        return true;
    // Clearing the scrollback moves the ends of its rows to the top-left of
    // what is left: both on screen cell (0, 0) is a selection whose rows went.
    GhosttyPointCoordinate s, e;
    if (ghostty_tracked_grid_ref_point(cast(GhosttyTrackedGridRef) sel.start,
            GHOSTTY_POINT_TAG_SCREEN, &s) == GHOSTTY_SUCCESS
        && ghostty_tracked_grid_ref_point(cast(GhosttyTrackedGridRef) sel.end,
            GHOSTTY_POINT_TAG_SCREEN, &e) == GHOSTTY_SUCCESS
        && s == GhosttyPointCoordinate.init && e == GhosttyPointCoordinate.init)
        return true;
    if (!blankAt(sel.start) || !blankAt(sel.end))
        return false;
    bool empty = true;
    cast(void) withSelectionText(t, sel, (scope const(char)[] x) {
        foreach (c; x)
            if (c > ' ')
            {
                empty = false;
                break;
            }
    });
    return empty;
}

private bool blankAt(in GhosttyTrackedGridRef tracked) @system nothrow @nogc
{
    GhosttyGridRef r;
    r.size = GhosttyGridRef.sizeof;
    if (ghostty_tracked_grid_ref_snapshot(cast(GhosttyTrackedGridRef) tracked, &r) != GHOSTTY_SUCCESS)
        return true;
    uint[4] cps;
    size_t len;
    const res = ghostty_grid_ref_graphemes(&r, cps.ptr, cps.length, &len);
    return (res != GHOSTTY_SUCCESS && res != GHOSTTY_OUT_OF_SPACE) || len == 0 || cps[0] <= ' ';
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests: a bare emulator, no pty.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private struct Vt
    {
        GhosttyTerminal t;
        SelectionState sel;

        @disable this(this);

        static Vt* open(ushort cols, ushort rows) @system
        {
            auto v = new Vt;
            GhosttyTerminalOptions o = {cols: cols, rows: rows, max_scrollback: 1000};
            assert(ghostty_terminal_new(null, &v.t, o) == GHOSTTY_SUCCESS);
            return v;
        }

        void close() @system
        {
            sel.free();
            ghostty_terminal_free(t);
        }

        void write(scope const(char)[] s) @system
            => ghostty_terminal_vt_write(t, cast(const(ubyte)*) s.ptr, s.length);

        string text() @system
        {
            string r;
            cast(void) withSelectionText(t, sel, (scope const(char)[] x) { r = x.idup; });
            return r;
        }

        void scroll(int delta) @system
        {
            GhosttyTerminalScrollViewport sv;
            sv.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
            sv.value.delta = delta;
            ghostty_terminal_scroll_viewport(t, sv);
        }
    }
}

@("selection.selectAt.wordUrlAndLine")
@system unittest
{
    auto v = Vt.open(40, 4);
    scope (exit) v.close();
    v.write("ls ~/src/app.d\r\nsee https://ex.org/a?b=1 ok\r\n");

    assert(selectAt(v.t, v.sel, 6, 0, 40, Granularity.word));
    assert(v.text == "~/src/app.d", "a path is one word");
    assert(selectAt(v.t, v.sel, 12, 1, 40, Granularity.word));
    assert(v.text == "https://ex.org/a?b=1", "a URL whole, query and all");
    assert(selectAt(v.t, v.sel, 0, 1, 40, Granularity.line));
    assert(v.text == "see https://ex.org/a?b=1 ok");
    assert(!selectAt(v.t, v.sel, 30, 1, 40, Granularity.word), "a blank selects nothing");
    assert(!selectionLive(v.sel));
}

@("selection.selectAt.followsSoftWraps")
@system unittest
{
    // A path the screen's width broke across rows is still one word.
    auto v = Vt.open(10, 8);
    scope (exit) v.close();
    v.write("ls ~/abcdefghijklmno x\r\nhttps://a.b/cdefghij ok");
    assert(selectAt(v.t, v.sel, 5, 0, 10, Granularity.word));
    assert(v.text == "~/abcdefghijklmno", "from the first row");
    assert(selectAt(v.t, v.sel, 2, 1, 10, Granularity.word));
    assert(v.text == "~/abcdefghijklmno", "from the second");
    assert(selectAt(v.t, v.sel, 3, 3, 10, Granularity.word));
    assert(v.text == "https://a.b/cdefghij", "a URL too");
}

@("selection.moveEnd.endsMayCross")
@system unittest
{
    auto v = Vt.open(20, 3);
    scope (exit) v.close();
    v.write("abcdefghij\r\n");
    assert(selectCells(v.t, v.sel, 4, 0, 6, 0));
    assert(v.text == "efg");
    // The start handle dragged past the end: the ends swap in reading order.
    assert(moveEnd(v.t, v.sel, SelectionEnd.start, 8, 0));
    const b = bounds(v.t, v.sel);
    assert(b.firstCol == 6 && b.lastCol == 8 && b.firstEnd == SelectionEnd.end);
    assert(v.text == "ghi");
}

@("selection.text.streamJoinsWrapsBlockJoinsRows")
@system unittest
{
    // `TSE2`: soft-wrapped rows join without a newline; a block's rows by \n.
    auto v = Vt.open(10, 4);
    scope (exit) v.close();
    v.write("0123456789abcdef\r\nxyz\r\n");
    assert(selectCells(v.t, v.sel, 0, 0, 5, 1));
    assert(v.text == "0123456789abcdef");
    assert(selectCells(v.t, v.sel, 1, 0, 2, 2, rectangular: true));
    assert(v.text == "12\nbc\nyz");
}

@("selection.bounds.followTheTextIntoScrollback")
@system unittest
{
    // `TSE4`: anchored in scrollback coordinates — output that scrolls the
    // text away keeps the selection on it.
    auto v = Vt.open(20, 4);
    scope (exit) v.close();
    v.write("one\r\ntwo\r\nthree");
    assert(selectAt(v.t, v.sel, 1, 1, 20, Granularity.word));
    assert(bounds(v.t, v.sel).firstRow == 1);
    v.write("\r\nfour\r\nfive\r\nsix");
    const b = bounds(v.t, v.sel);
    assert(b.firstRow == -1 && b.lastRow == -1, "a row above the viewport");
    assert(v.text == "two");
    v.scroll(-1);
    assert(bounds(v.t, v.sel).firstRow == 0, "scrolled back into view");
}

@("selection.selectAll.coversScrollback")
@system unittest
{
    auto v = Vt.open(20, 2);
    scope (exit) v.close();
    v.write("first\r\nsecond\r\nthird");
    assert(selectAll(v.t, v.sel));
    assert(v.text == "first\nsecond\nthird");
    assert(bounds(v.t, v.sel).firstRow < 0);
}

@("selection.selectionEmptied.clearingTheScreenOrScrollback")
@system unittest
{
    auto v = Vt.open(20, 3);
    scope (exit) v.close();
    v.write("a\r\nb\r\nc\r\nd\r\nword");
    assert(selectAt(v.t, v.sel, 0, 0, 20, Granularity.word));
    assert(!selectionEmptied(v.t, v.sel));
    v.write("\x1b[2J"); // erase the screen: `clear`'s second half
    assert(selectionEmptied(v.t, v.sel));

    // Scrolled into the scrollback, then the scrollback cleared.
    v.write("\x1b[Hword\r\n1\r\n2\r\n3\r\n4");
    assert(selectAll(v.t, v.sel) && !selectionEmptied(v.t, v.sel));
    assert(selectCells(v.t, v.sel, 0, 0, 3, 0) && v.text == "2");
    v.write("\r\n5\r\n6\r\n7");
    assert(!selectionEmptied(v.t, v.sel), "output only scrolled it away");
    v.write("\x1b[3J");
    assert(selectionEmptied(v.t, v.sel), "`clear`'s first half");
}
