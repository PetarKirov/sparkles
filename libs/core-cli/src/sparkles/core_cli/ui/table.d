module sparkles.core_cli.ui.table;

import std.array : array, appender;
import std.algorithm : map, all, maxElement, sort;
import std.algorithm.comparison : max, min;
import std.range : iota;

import expected : Expected, ok, err;

import sparkles.base.text.grapheme : visibleWidth;
import sparkles.base.text.width : Align, alignField;

bool hasRectangularShape(T)(const T[][] array)
{
    size_t width = array[0].length;
    return array.all!(row => row.length == width);
}

unittest
{
    assert([[]].hasRectangularShape());
    assert([[1]].hasRectangularShape());
    assert([[], []].hasRectangularShape());
    assert([[1], [2]].hasRectangularShape());
    assert([[], [], []].hasRectangularShape());
    assert([[1], [2], [3]].hasRectangularShape());
    assert([[1, 2], [3, 4], [5, 6]].hasRectangularShape());
    assert([[1, 2, 3], [4, 5, 6], [7, 8, 9]].hasRectangularShape());

    assert(![[], [1], [1, 2]].hasRectangularShape());
    assert(![[1, 2], [1], [1, 2]].hasRectangularShape());
    assert(![[1], [2], [3, 3], []].hasRectangularShape());
    assert(![[1, 2], [3, 4], []].hasRectangularShape());
}

size_t[] columnWidths(string[][] cells)
in (hasRectangularShape(cells))
{
    return cells[0].length
        .iota
        .map!(col => cells.map!(row => visibleWidth(row[col])).maxElement())
        .array;
}

unittest
{
    assert(columnWidths([[""]]) == [0]);
    assert(columnWidths([
        ["1", "123"],
        ["12", ""]
    ]) == [2, 3]);
    assert(columnWidths([
        ["1234", "1"],
        ["1", ""],
        ["123", "12345"],
        ["", "12"]
    ]) == [4, 5]);
}

// ---------------------------------------------------------------------------
// Span-capable table model (see docs/specs/core-cli/table.md)
//
// Authoring is a dense `string[][]` (rectangular, extent-1) — the public
// `drawTable` overload below. Internally it lowers to an HTML "slot grid": every
// cell is an `Anchor` at `(row, col)` covering a `rowSpan × colSpan` rectangle,
// and coverage is *derived* (`slotOwner`), never stored. The renderer is a
// pipeline of free functions over that grid, so it is testable in isolation and
// span-ready even though this overload only produces extent-1 anchors.
// ---------------------------------------------------------------------------

/// The configurable box-drawing glyph set. Defaults are the rounded frame plus the
/// square interior corners spans create; every field is a caller-overridable `dchar`.
struct TableGlyphs
{
    dchar topLeft = '╭', topRight = '╮', bottomLeft = '╰', bottomRight = '╯';
    dchar horizontalLine = '─', verticalLine = '│';
    dchar teeDown = '┬', teeUp = '┴', teeRight = '├', teeLeft = '┤', cross = '┼';
    dchar cornerTL = '┌', cornerTR = '┐', cornerBL = '└', cornerBR = '┘';
}

/// Vertical alignment of a cell's content within its (possibly multi-line or rowspan)
/// height. `inherit` defers to the column/table default.
enum VAlign { inherit, top, middle, bottom }

/// Table rendering configuration. Defaults reproduce the pre-overhaul rendering
/// byte-for-byte: rounded glyphs, column separators on, row separators off, outer
/// border on, left/top alignment.
struct TableProps
{
    TableGlyphs glyphs;            /// Box-drawing glyph set.
    bool border           = true; /// Draw the outer frame.
    bool columnSeparators = true; /// Draw interior vertical `│` lines.
    bool rowSeparators    = false;/// Draw interior horizontal `─` rules.

    /// Total table width cap in columns, **including** separators and borders, or 0
    /// for no cap (expand to fit — today's behaviour). When set, columns are shrunk
    /// largest-first and their content wraps so no rendered line exceeds it. Feed it
    /// the terminal width (e.g. via `sparkles.core_cli.term_size`) to fit output.
    size_t maxWidth = 0;

    /// Per-column max **content** width (excluding separators/gutters); a `0` entry or
    /// a short/empty array means that column is unbounded. Content over a column's cap
    /// wraps.
    size_t[] columnMaxWidths = null;

    /// Horizontal alignment. `columnAligns[c]` (when in range and not `inherit`)
    /// overrides `defaultAlign` for column `c`.
    Align    defaultAlign  = Align.left;
    Align[]  columnAligns   = null; /// ditto
    /// Vertical alignment (governs rowspan / multi-line cells). `columnVAligns[c]`
    /// (when in range and not `inherit`) overrides `defaultVAlign` for column `c`.
    VAlign   defaultVAlign = VAlign.top;
    VAlign[] columnVAligns  = null; /// ditto
}

/// The effective horizontal alignment for column `c`: the per-column override if set,
/// else the table default (`inherit` resolves to `left`).
private Align effectiveAlign(size_t c, in TableProps p) @safe pure nothrow @nogc
{
    if (c < p.columnAligns.length && p.columnAligns[c] != Align.inherit)
        return p.columnAligns[c];
    return p.defaultAlign == Align.inherit ? Align.left : p.defaultAlign;
}

/// The effective vertical alignment for column `c` (`inherit` resolves to `top`).
private VAlign effectiveVAlign(size_t c, in TableProps p) @safe pure nothrow @nogc
{
    if (c < p.columnVAligns.length && p.columnVAligns[c] != VAlign.inherit)
        return p.columnVAligns[c];
    return p.defaultVAlign == VAlign.inherit ? VAlign.top : p.defaultVAlign;
}

/// Blank lines above a content block of `l` lines placed in a field of `hh` lines.
private size_t padTop(size_t hh, size_t l, VAlign va) @safe pure nothrow @nogc
{
    if (hh <= l)
        return 0;
    final switch (va)
    {
        case VAlign.inherit:
        case VAlign.top:    return 0;
        case VAlign.middle: return (hh - l) / 2;
        case VAlign.bottom: return hh - l;
    }
}

/// Named glyph presets, selectable as `TableProps(glyphs: stylePresets["ascii"])`.
/// Seeded with `rounded` (the default, `== TableGlyphs.init`), `square`, `ascii`,
/// `double`, and `heavy`; callers may register or override their own entries. Thread
/// local (each thread gets the built-ins), so reads stay `@safe`.
TableGlyphs[string] stylePresets;

static this()
{
    stylePresets["rounded"] = TableGlyphs.init;
    stylePresets["square"] = TableGlyphs(
        topLeft: '┌', topRight: '┐', bottomLeft: '└', bottomRight: '┘',
        horizontalLine: '─', verticalLine: '│',
        teeDown: '┬', teeUp: '┴', teeRight: '├', teeLeft: '┤', cross: '┼',
        cornerTL: '┌', cornerTR: '┐', cornerBL: '└', cornerBR: '┘');
    stylePresets["ascii"] = TableGlyphs(
        topLeft: '+', topRight: '+', bottomLeft: '+', bottomRight: '+',
        horizontalLine: '-', verticalLine: '|',
        teeDown: '+', teeUp: '+', teeRight: '+', teeLeft: '+', cross: '+',
        cornerTL: '+', cornerTR: '+', cornerBL: '+', cornerBR: '+');
    stylePresets["double"] = TableGlyphs(
        topLeft: '╔', topRight: '╗', bottomLeft: '╚', bottomRight: '╝',
        horizontalLine: '═', verticalLine: '║',
        teeDown: '╦', teeUp: '╩', teeRight: '╠', teeLeft: '╣', cross: '╬',
        cornerTL: '╔', cornerTR: '╗', cornerBL: '╚', cornerBR: '╝');
    stylePresets["heavy"] = TableGlyphs(
        topLeft: '┏', topRight: '┓', bottomLeft: '┗', bottomRight: '┛',
        horizontalLine: '━', verticalLine: '┃',
        teeDown: '┳', teeUp: '┻', teeRight: '┣', teeLeft: '┫', cross: '╋',
        cornerTL: '┏', cornerTR: '┓', cornerBL: '┗', cornerBR: '┛');
}

/// One content object anchored at `(row, col)` covering a `rowSpan × colSpan`
/// rectangle of slots. `implicit` marks a filler synthesized for a slot no authored
/// cell covers (keeps the grid fully populated).
private struct Anchor
{
    size_t row, col, rowSpan, colSpan;
    string content;
    bool implicit;
}

/// The resolved grid: dimensions, the anchor list, and a slot→anchor map so
/// `owner(r, c)` is O(1). Coverage is derived from this, never stored per anchor.
private struct SlotGrid
{
    size_t numRows, numCols;
    Anchor[] anchors;
    size_t[] slotOwner; // [r*numCols + c] -> index into anchors
}

/// A table cell for the dense authoring form `Cell[][]`. `colSpan`/`rowSpan` (default
/// 1) make it cover a rectangle of grid slots; the slots it covers are **omitted**
/// from the following cells of this and later rows (the placement cursor skips them).
/// A plain `string[][]` is sugar for extent-1 cells.
struct Cell
{
    string content;    /// Cell text (may contain `\n`; wraps to the column width).
    size_t colSpan = 1;/// Number of columns this cell spans.
    size_t rowSpan = 1;/// Number of rows this cell spans.
}

/// A cell for the sparse authoring form `Placement[]`: it names its own `(row, col)`
/// and extent, so placements are order-independent and never need filler for the gaps
/// (uncovered slots become implicit blanks). Equivalent in power to `Cell[][]`.
struct Placement
{
    size_t row;        /// Anchor row (0-based).
    size_t col;        /// Anchor column (0-based).
    string content;    /// Cell text (may contain `\n`; wraps to the column width).
    size_t colSpan = 1;/// Number of columns this cell spans.
    size_t rowSpan = 1;/// Number of rows this cell spans.
}

/// What kind of table-model error `validateTable` found.
enum TableErrorKind
{
    overlap,            /// Two cells cover the same slot.
    rowSpanOutOfBounds, /// A rowspan extended past the last authored row (clamped).
}

/// A table-model error. `drawTable` renders a malformed table deterministically anyway
/// (first-writer-wins on overlap, rowspans clamped); `validateTable` surfaces these for
/// callers that want to reject one. `row`/`col` locate the offending slot or anchor.
struct TableError
{
    TableErrorKind kind;
    size_t row;
    size_t col;
    string message;
}

/// A resolved grid together with any table-model errors found while placing it.
private struct Resolved
{
    SlotGrid grid;
    TableError[] errors;
}

private Cell[][] toCells(in string[][] rows) @safe pure nothrow
{
    auto out_ = new Cell[][](rows.length);
    foreach (r, row; rows)
    {
        out_[r] = new Cell[](row.length);
        foreach (c, s; row)
            out_[r][c] = Cell(s);
    }
    return out_;
}

/// Place cells on the grid with the HTML "forming a table" cursor: walk row-major,
/// skip already-covered slots, claim each anchor's rectangle (first-writer-wins),
/// clamp rowspans past the last authored row, then fill every uncovered slot with an
/// implicit empty anchor so the grid is fully populated (always renderable). Overlaps
/// and clamped rowspans are recorded as `TableError`s.
private Resolved resolveGrid(in Cell[][] rows) @safe pure nothrow
{
    Anchor[] anchors;
    TableError[] errors;
    bool[][] occ;
    size_t[][] owner; // anchor index + 1; 0 == empty
    occ.length = rows.length;
    owner.length = rows.length;
    size_t numCols;

    void ensure(size_t r, size_t c) @safe pure nothrow
    {
        if (r >= occ.length)
        {
            occ.length = r + 1;
            owner.length = r + 1;
        }
        if (c >= occ[r].length)
        {
            occ[r].length = c + 1;
            owner[r].length = c + 1;
        }
    }

    const numRows = rows.length;
    foreach (r, row; rows)
    {
        size_t c = 0;
        foreach (cell; row)
        {
            for (;;) // advance past slots an earlier anchor already covers
            {
                ensure(r, c);
                if (occ[r][c])
                    c++;
                else
                    break;
            }
            const cs = cell.colSpan < 1 ? 1 : cell.colSpan;
            const rs = cell.rowSpan < 1 ? 1 : cell.rowSpan;
            const idx = anchors.length;
            anchors ~= Anchor(r, c, rs, cs, cell.content, false);
            if (r + rs > numRows)
                errors ~= TableError(TableErrorKind.rowSpanOutOfBounds, r, c,
                    "rowspan extends past the last row");
            foreach (dr; 0 .. rs)
                foreach (dc; 0 .. cs)
                {
                    ensure(r + dr, c + dc);
                    if (occ[r + dr][c + dc]) // first-writer-wins; record the collision
                        errors ~= TableError(TableErrorKind.overlap, r + dr, c + dc,
                            "cell overlaps another");
                    else
                    {
                        occ[r + dr][c + dc] = true;
                        owner[r + dr][c + dc] = idx + 1;
                    }
                }
            numCols = max(numCols, c + cs);
            c += cs;
        }
    }

    return Resolved(finalizeGrid(anchors, occ, owner, numRows, numCols), errors);
}

/// The sparse authoring form: each `Placement` claims its rectangle at its own
/// `(row, col)` (no cursor). Same first-writer-wins overlap handling, rowspan clamp,
/// and implicit sparse-fill as the dense path, producing an identical `SlotGrid` — so
/// both feed the one renderer. Grid dimensions are inferred from the max extents used.
private Resolved resolveGrid(in Placement[] placements) @safe pure nothrow
{
    Anchor[] anchors;
    TableError[] errors;
    bool[][] occ;
    size_t[][] owner; // anchor index + 1; 0 == empty
    size_t numRows, numCols;

    void ensure(size_t r, size_t c) @safe pure nothrow
    {
        if (r >= occ.length)
        {
            occ.length = r + 1;
            owner.length = r + 1;
        }
        if (c >= occ[r].length)
        {
            occ[r].length = c + 1;
            owner[r].length = c + 1;
        }
    }

    foreach (pl; placements)
    {
        const cs = pl.colSpan < 1 ? 1 : pl.colSpan;
        const rs = pl.rowSpan < 1 ? 1 : pl.rowSpan;
        const idx = anchors.length;
        anchors ~= Anchor(pl.row, pl.col, rs, cs, pl.content, false);
        foreach (dr; 0 .. rs)
            foreach (dc; 0 .. cs)
            {
                ensure(pl.row + dr, pl.col + dc);
                if (occ[pl.row + dr][pl.col + dc]) // first-writer-wins; record collision
                    errors ~= TableError(TableErrorKind.overlap, pl.row + dr, pl.col + dc,
                        "cell overlaps another");
                else
                {
                    occ[pl.row + dr][pl.col + dc] = true;
                    owner[pl.row + dr][pl.col + dc] = idx + 1;
                }
            }
        numRows = max(numRows, pl.row + rs);
        numCols = max(numCols, pl.col + cs);
    }

    return Resolved(finalizeGrid(anchors, occ, owner, max(numRows, occ.length), numCols), errors);
}

/// Clamp any rowspan past the last row, fill every uncovered slot with an implicit
/// empty anchor, and build the slot→anchor map. Shared by both `resolveGrid` overloads
/// so dense and sparse inputs produce the same fully-populated (always renderable) grid.
private SlotGrid finalizeGrid(Anchor[] anchors, bool[][] occ, size_t[][] owner,
    size_t numRows, size_t numCols) @safe pure nothrow
{
    foreach (ref a; anchors)
        if (a.row + a.rowSpan > numRows)
            a.rowSpan = numRows - a.row;

    auto slotOwner = new size_t[numRows * numCols];
    foreach (r; 0 .. numRows)
        foreach (c; 0 .. numCols)
        {
            const o = (r < owner.length && c < owner[r].length) ? owner[r][c] : 0;
            if (o == 0)
            {
                slotOwner[r * numCols + c] = anchors.length;
                anchors ~= Anchor(r, c, 1, 1, "", true);
            }
            else
                slotOwner[r * numCols + c] = o - 1;
        }

    return SlotGrid(numRows, numCols, anchors, slotOwner);
}

private size_t owner(in SlotGrid g, size_t r, size_t c) @safe pure nothrow @nogc
    => g.slotOwner[r * g.numCols + c];

/// The visible-column field a cell occupies: its member column widths plus, per
/// merged boundary, the two gutters and the `sepW` separator column it absorbs
/// (`sepW == 1` with column separators on, else 0).
private size_t contentField(in Anchor a, in size_t[] w, size_t sepW) @safe pure nothrow @nogc
{
    size_t f = (2 + sepW) * (a.colSpan - 1);
    foreach (c; a.col .. a.col + a.colSpan)
        f += w[c];
    return f;
}

/// Per-column content widths: per-column max of extent-1 anchors (== the legacy
/// `columnWidths` base case), then grow member columns so every colspan cell fits.
/// The intrinsic width of a cell's content: the widest of its own lines (content may
/// carry embedded `\n`), so a multi-line cell is not sized by its newline-joined length.
private size_t naturalWidth(string content) @safe pure nothrow
{
    import std.string : lineSplitter;

    size_t m = 0;
    foreach (seg; content.lineSplitter)
        m = max(m, visibleWidth(seg));
    return m;
}

private size_t[] resolveColumnWidths(in SlotGrid g, in TableProps p) @safe pure nothrow
{
    const sepW = p.columnSeparators ? 1 : 0;
    auto w = new size_t[g.numCols];
    foreach (ref a; g.anchors)
        if (a.colSpan == 1)
            w[a.col] = max(w[a.col], naturalWidth(a.content));

    // Satisfy colspan cells ascending by span then position: columns only grow, so
    // one pass leaves every spanning cell fitting its final member-column widths.
    Anchor[] spanning;
    foreach (a; g.anchors)
        if (a.colSpan >= 2)
            spanning ~= a;
    spanning.sort!((a, b) => a.colSpan != b.colSpan ? a.colSpan < b.colSpan
            : (a.row != b.row ? a.row < b.row : a.col < b.col));
    foreach (a; spanning)
    {
        const n = a.colSpan;
        const vw = naturalWidth(a.content);
        const absorbed = (2 + sepW) * (n - 1); // gutters + separators the span covers
        const required = vw > absorbed ? vw - absorbed : 0;
        size_t cur = 0;
        foreach (c; a.col .. a.col + n)
            cur += w[c];
        if (required > cur)
        {
            const deficit = required - cur;
            const base = deficit / n;
            const extra = deficit % n;
            foreach (k; 0 .. n)
                w[a.col + k] += base + (k < extra ? 1 : 0);
        }
    }

    // Per-column caps: content over a column's max wraps instead of widening it.
    foreach (c; 0 .. g.numCols)
        if (c < p.columnMaxWidths.length && p.columnMaxWidths[c] > 0)
            w[c] = min(w[c], p.columnMaxWidths[c]);

    // Total-width cap: shrink the widest column by 1 until the whole table fits
    // `maxWidth` (frame included), flooring each column at 1. Trimmed columns wrap.
    if (p.maxWidth > 0)
    {
        const borderW = p.border ? 1 : 0;
        const frame = 2 * g.numCols + sepW * (g.numCols - 1) + 2 * borderW;
        for (;;)
        {
            size_t total = frame;
            foreach (c; 0 .. g.numCols)
                total += w[c];
            if (total <= p.maxWidth)
                break;
            // Widest column (leftmost on a tie) that can still lose a column.
            size_t widest = 0;
            bool any = false;
            foreach (c; 0 .. g.numCols)
                if (w[c] > 1 && (!any || w[c] > w[widest]))
                {
                    widest = c;
                    any = true;
                }
            if (!any)
                break; // every column already at its floor of 1
            w[widest] -= 1;
        }
    }
    return w;
}

/// Is a vertical grid segment drawn on boundary `j` within band `r`? Frame edges
/// follow `border`; interior verticals follow `columnSeparators` and vanish where a
/// colspan crosses (the same anchor owns both sides).
private bool vSeg(in SlotGrid g, in TableProps p, size_t r, size_t j) @safe pure nothrow @nogc
{
    if (j == 0 || j == g.numCols)
        return p.border;
    if (!p.columnSeparators)
        return false;
    return owner(g, r, j - 1) != owner(g, r, j);
}

/// Is a horizontal grid segment drawn on rule `i` within column `c`? Frame edges
/// follow `border`; interior rules follow `rowSeparators` and vanish where a rowspan
/// crosses.
private bool hSeg(in SlotGrid g, in TableProps p, size_t i, size_t c) @safe pure nothrow @nogc
{
    if (i == 0 || i == g.numRows)
        return p.border;
    if (!p.rowSeparators)
        return false;
    return owner(g, i - 1, c) != owner(g, i, c);
}

/// The box-drawing glyph at lattice intersection `(i, j)`, from which of its four
/// arms are real drawn segments. Extreme table corners use the rounded frame glyphs;
/// every other intersection maps purely from the 4-arm mask (square interior corners).
private dchar junctionGlyph(in SlotGrid g, in TableProps p, size_t i, size_t j) @safe pure nothrow @nogc
{
    const bool tE = i == 0, bE = i == g.numRows, lE = j == 0, rE = j == g.numCols;
    const bool u = i > 0 && vSeg(g, p, i - 1, j);
    const bool d = i < g.numRows && vSeg(g, p, i, j);
    const bool l = j > 0 && hSeg(g, p, i, j - 1);
    const bool r = j < g.numCols && hSeg(g, p, i, j);

    if ((tE || bE) && (lE || rE))
    {
        if (!(u || d || l || r))
            return ' ';
        if (tE && lE)
            return p.glyphs.topLeft;
        if (tE && rE)
            return p.glyphs.topRight;
        if (bE && lE)
            return p.glyphs.bottomLeft;
        return p.glyphs.bottomRight;
    }

    const m = (u << 3) | (d << 2) | (l << 1) | r;
    final switch (m)
    {
        case 0b0000: return ' ';
        case 0b0001: case 0b0010: case 0b0011: return p.glyphs.horizontalLine;
        case 0b0100: case 0b1000: case 0b1100: return p.glyphs.verticalLine;
        case 0b0101: return p.glyphs.cornerTL; // down + right
        case 0b0110: return p.glyphs.cornerTR; // down + left
        case 0b1001: return p.glyphs.cornerBL; // up + right
        case 0b1010: return p.glyphs.cornerBR; // up + left
        case 0b0111: return p.glyphs.teeDown;
        case 0b1011: return p.glyphs.teeUp;
        case 0b1101: return p.glyphs.teeRight;
        case 0b1110: return p.glyphs.teeLeft;
        case 0b1111: return p.glyphs.cross;
    }
}

/// One horizontal rule (top border, interior row separator, or bottom border) at
/// lattice row `i`: junctions interleaved with per-column fills.
private string separatorLine(in SlotGrid g, in size_t[] w, in TableProps p, size_t i)
{
    // A lattice column is 1 char wide only when its line is drawn: the outer two
    // follow `border`, the interior ones `columnSeparators`. A zero-width lattice is
    // skipped in both bands and rules, so the two always share the same width.
    auto line = appender!string;
    foreach (j; 0 .. g.numCols)
    {
        const latticeDrawn = j == 0 ? p.border : p.columnSeparators;
        if (latticeDrawn)
            line ~= junctionGlyph(g, p, i, j);
        const fillCh = hSeg(g, p, i, j) ? p.glyphs.horizontalLine : ' ';
        foreach (_; 0 .. w[j] + 2)
            line ~= fillCh;
    }
    if (p.border)
        line ~= junctionGlyph(g, p, i, g.numCols);
    line ~= '\n';
    return line[];
}

/// Wrap every anchor's content into its `contentField` width, splitting on `\n` and
/// soft-wrapping long lines with the shared `sparkles.base.text.wrap` engine (the same
/// one `drawBox` uses). Trailing spaces left at a wrap point are trimmed so a wrapped
/// line never exceeds the field. Returns one line list per anchor (empty content → a
/// single blank line), indexed like `SlotGrid.anchors`.
private string[][] wrapCells(in SlotGrid g, in size_t[] w, in TableProps p)
{
    import sparkles.base.text.wrap : byWrappedLine, WhitespaceMode, WrapOptions;
    import std.string : lineSplitter, stripRight;

    const sepW = p.columnSeparators ? 1 : 0;
    auto result = new string[][](g.anchors.length);
    foreach (i, ref a; g.anchors)
    {
        const f = contentField(a, w, sepW);
        string[] lines;
        foreach (seg; a.content.lineSplitter)
        {
            if (f == 0)
            {
                lines ~= "";
                continue;
            }
            bool any = false;
            foreach (wl; seg.byWrappedLine(
                    WrapOptions(width: f, whitespace: WhitespaceMode.preserve)))
            {
                any = true;
                lines ~= wl.stripRight.idup;
            }
            if (!any)
                lines ~= "";
        }
        if (lines.length == 0)
            lines ~= ""; // empty content still occupies one blank line
        result[i] = lines;
    }
    return result;
}

/// Per grid-row text height (≥ 1): the max wrapped-line count among extent-1 cells,
/// then grown so every rowspan cell's lines fit across its bands' combined height
/// (ascending by span; rows only grow, so one pass satisfies all — like the colspan
/// width distribution).
private size_t[] resolveRowHeights(in SlotGrid g, in string[][] lines) @safe pure nothrow
{
    auto h = new size_t[g.numRows];
    foreach (ref x; h)
        x = 1;
    foreach (i, ref a; g.anchors)
        if (a.rowSpan == 1)
            h[a.row] = max(h[a.row], lines[i].length);

    size_t[] spanning;
    foreach (i, ref a; g.anchors)
        if (a.rowSpan >= 2)
            spanning ~= i;
    spanning.sort!((x, y) => g.anchors[x].rowSpan != g.anchors[y].rowSpan
            ? g.anchors[x].rowSpan < g.anchors[y].rowSpan
            : (g.anchors[x].row != g.anchors[y].row ? g.anchors[x].row < g.anchors[y].row
                : g.anchors[x].col < g.anchors[y].col));
    foreach (i; spanning)
    {
        const a = g.anchors[i];
        const need = lines[i].length;
        const k = a.rowSpan;
        size_t cur = 0;
        foreach (rr; a.row .. a.row + k)
            cur += h[rr];
        if (need > cur)
        {
            const deficit = need - cur;
            const base = deficit / k;
            const extra = deficit % k;
            foreach (t; 0 .. k)
                h[a.row + t] += base + (t < extra ? 1 : 0);
        }
    }
    return h;
}

/// Render all text lines of grid row `r` (its height is `heights[r]`). Each anchor
/// emits its wrapped line for the current text line in its content band, or a blank
/// field otherwise, separated by interior verticals where a real boundary sits.
private string bodyRow(in SlotGrid g, in size_t[] w, in string[][] lines,
    in size_t[] heights, in TableProps p, size_t r)
{
    const sepW = p.columnSeparators ? 1 : 0;
    auto out_ = appender!string;
    foreach (t; 0 .. heights[r])
    {
        if (p.border)
            out_ ~= p.glyphs.verticalLine;
        size_t c = 0;
        while (c < g.numCols)
        {
            const idx = owner(g, r, c);
            const a = g.anchors[idx];
            const f = contentField(a, w, sepW);
            // This anchor's line index at row r, text line t: the sum of the heights
            // of its bands above r, plus t. For an extent-1 cell that is just t; a
            // rowspan cell's content flows down across its stacked bands.
            size_t li = t;
            foreach (rr; a.row .. r)
                li += heights[rr];
            // Vertical alignment shifts the content block down within the anchor's
            // combined height; horizontal alignment is applied per line.
            size_t hh = 0;
            foreach (rr; a.row .. a.row + a.rowSpan)
                hh += heights[rr];
            const top = padTop(hh, lines[idx].length, effectiveVAlign(a.col, p));
            out_ ~= ' ';
            if (li >= top && li - top < lines[idx].length)
                alignField(out_, lines[idx][li - top], f, effectiveAlign(a.col, p));
            else
                foreach (_; 0 .. f)
                    out_ ~= ' ';
            out_ ~= ' ';
            c += a.colSpan;
            if (c < g.numCols && vSeg(g, p, r, c))
                out_ ~= p.glyphs.verticalLine;
        }
        if (p.border)
            out_ ~= p.glyphs.verticalLine;
        out_ ~= '\n';
    }
    return out_[];
}

/// Render a resolved grid: top border, then each (multi-line) body row with interior
/// rules between rows when `rowSeparators`, then the bottom border.
private string drawGrid(in SlotGrid g, in TableProps p)
{
    if (g.numRows == 0 || g.numCols == 0)
        return "";
    auto w = resolveColumnWidths(g, p);
    auto lines = wrapCells(g, w, p);
    auto heights = resolveRowHeights(g, lines);
    auto out_ = appender!string;
    if (p.border)
        out_ ~= separatorLine(g, w, p, 0);
    foreach (r; 0 .. g.numRows)
    {
        out_ ~= bodyRow(g, w, lines, heights, p, r);
        if (r + 1 < g.numRows && p.rowSeparators)
            out_ ~= separatorLine(g, w, p, r + 1);
    }
    if (p.border)
        out_ ~= separatorLine(g, w, p, g.numRows);
    return out_[];
}

/// Render a rectangular `string[][]` as a boxed table. With the default
/// `TableProps` the output is byte-identical to the pre-overhaul renderer.
string drawTable(string[][] cells, TableProps props = TableProps.init)
in (hasRectangularShape(cells))
{
    return drawGrid(resolveGrid(toCells(cells)).grid, props);
}

/// Render a dense `Cell[][]` (cells may carry `colSpan`/`rowSpan`) as a boxed table.
/// Covered slots are omitted from the following cells (rows may be ragged); the
/// placement cursor recovers their positions. Malformed tables (overlap, over-long
/// rowspans) still render deterministically — use `validateTable` to detect them.
/// See `Cell`.
string drawTable(Cell[][] cells, TableProps props = TableProps.init)
{
    return drawGrid(resolveGrid(cells).grid, props);
}

/// Render a sparse `Placement[]` (order-independent cells naming their own
/// `(row, col)` and extent) as a boxed table. Lowers to the same slot grid as the
/// dense forms, so it renders identically. See `Placement`.
string drawTable(Placement[] cells, TableProps props = TableProps.init)
{
    return drawGrid(resolveGrid(cells).grid, props);
}

/// Validate a table's cell placement, returning the first table-model error (overlap
/// or an over-long rowspan) or `true` when the table is well-formed. `drawTable`
/// renders either way; call this first when a malformed table should be rejected.
/// Works with the dense `Cell[][]` or sparse `Placement[]` form.
Expected!(bool, TableError) validateTable(T)(in T[] cells)
if (is(T == Cell[]) || is(T == Placement))
{
    auto r = resolveGrid(cells);
    return r.errors.length ? err!bool(r.errors[0]) : ok!TableError(true);
}

unittest
{
    import sparkles.test_utils.string : outdent;
    import std.stdio;
    void check(string actual, string expected)
    {
        import sparkles.test_utils;
        if (actual != expected)
        {
            diffWithTool(actual, expected, false, DiffTools.deltaUserConfig).writeln;
            assert(0);
        }
    }

    check(drawTable([["x"]]), `
        ╭───╮
        │ x │
        ╰───╯
        `.outdent(2));

    check(drawTable([["123"]]), `
        ╭─────╮
        │ 123 │
        ╰─────╯
        `.outdent(2));

    check(drawTable([["123", "ab"], ["c", "asdasd"]]), `
        ╭─────┬────────╮
        │ 123 │ ab     │
        │ c   │ asdasd │
        ╰─────┴────────╯
        `.outdent(2));
}

@("drawTable.styledContent")
@system unittest
{
    import sparkles.base.term_style : Style, stylize;
    import sparkles.test_utils.string : outdent;
    import std.stdio;

    void check(string actual, string expected)
    {
        import sparkles.test_utils;
        if (actual != expected)
        {
            diffWithTool(actual, expected, false, DiffTools.deltaUserConfig).writeln;
            assert(0);
        }
    }

    // Test that styled content is properly aligned
    // "OK" styled with green should still align with "Warning"
    check(drawTable([
        ["Status", "Value"],
        ["OK".stylize(Style.green), "Good"],
        ["Warning".stylize(Style.yellow), "Check"],
    ]),
        "╭─────────┬───────╮\n" ~
        "│ Status  │ Value │\n" ~
        "│ \x1b[32mOK\x1b[39m      │ Good  │\n" ~
        "│ \x1b[33mWarning\x1b[39m │ Check │\n" ~
        "╰─────────┴───────╯\n");
}

version (unittest) private void checkRender(string actual, string expected)
{
    import sparkles.test_utils : diffWithTool, DiffTools;
    import std.stdio : writeln;

    if (actual != expected)
    {
        diffWithTool(actual, expected, false, DiffTools.deltaUserConfig).writeln;
        assert(0, "table render mismatch");
    }
}

@("drawTable.presets.ascii")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    checkRender(drawTable([["ab", "c"], ["d", "ef"]], TableProps(glyphs: stylePresets["ascii"])),
        "+----+----+\n" ~
        "| ab | c  |\n" ~
        "| d  | ef |\n" ~
        "+----+----+\n");
}

@("drawTable.presets.registry")
@system unittest
{
    // The default glyphs are the rounded preset, and every built-in style is seeded.
    assert(stylePresets["rounded"] == TableGlyphs.init);
    foreach (name; ["rounded", "square", "ascii", "double", "heavy"])
        assert(name in stylePresets);

    // Each style's own corner/junction glyphs reach the output.
    assert(drawTable([["x", "y"]], TableProps(glyphs: stylePresets["double"]))
        == "╔═══╦═══╗\n║ x ║ y ║\n╚═══╩═══╝\n");
    assert(drawTable([["x", "y"]], TableProps(glyphs: stylePresets["heavy"]))
        == "┏━━━┳━━━┓\n┃ x ┃ y ┃\n┗━━━┻━━━┛\n");
    assert(drawTable([["x", "y"]], TableProps(glyphs: stylePresets["square"]))
        == "┌───┬───┐\n│ x │ y │\n└───┴───┘\n");
}

@("drawTable.separators.rowSeparators")
@system unittest
{
    checkRender(drawTable([["ab", "c"], ["d", "ef"]], TableProps(rowSeparators: true)),
        "╭────┬────╮\n" ~
        "│ ab │ c  │\n" ~
        "├────┼────┤\n" ~
        "│ d  │ ef │\n" ~
        "╰────┴────╯\n");
}

@("drawTable.separators.noColumnSeparators")
@system unittest
{
    // No interior verticals: the boundary lattice is zero-width, so the frame rules
    // are solid and columns abut with their gutters. Every line stays the same width.
    checkRender(drawTable([["ab", "c"], ["d", "ef"]], TableProps(columnSeparators: false)),
        "╭────────╮\n" ~
        "│ ab  c  │\n" ~
        "│ d   ef │\n" ~
        "╰────────╯\n");
}

@("drawTable.separators.noBorder")
@system unittest
{
    // No outer frame: only the interior column separators remain.
    checkRender(drawTable([["ab", "c"], ["d", "ef"]], TableProps(border: false)),
        " ab │ c  \n" ~
        " d  │ ef \n");
}

@("drawTable.separators.widthParityAllToggles")
@system unittest
{
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;

    // Bands and rules must share a width in every toggle combination.
    string[][] cells = [["ab", "c", "xyz"], ["d", "ef", "g"]];
    foreach (border; [false, true])
        foreach (colSep; [false, true])
            foreach (rowSep; [false, true])
            {
                const rendered = drawTable(cells,
                    TableProps(border: border, columnSeparators: colSep, rowSeparators: rowSep));
                const lines = rendered.splitLines;
                foreach (l; lines)
                    assert(l.visibleWidth == lines[0].visibleWidth,
                        "width parity broken for a toggle combination");
            }
}

@("drawTable.glyphs.customOverride")
@system unittest
{
    // A per-field override on top of a preset takes effect (double-line frame but an
    // ASCII '+' cross would only show with interior rules; here override the corners).
    auto glyphs = stylePresets["rounded"];
    glyphs.topLeft = '*';
    glyphs.topRight = '*';
    assert(drawTable([["x"]], TableProps(glyphs: glyphs)) == "*───*\n│ x │\n╰───╯\n");
}

@("drawTable.wrap.columnMaxWidth")
@system unittest
{
    // A cell over its column cap wraps to multiple lines; the row grows and the
    // shorter neighbour pads with blank lines.
    checkRender(drawTable([["hello world", "x"]], TableProps(columnMaxWidths: [5, 0])),
        "╭───────┬───╮\n" ~
        "│ hello │ x │\n" ~
        "│ world │   │\n" ~
        "╰───────┴───╯\n");
}

@("drawTable.wrap.embeddedNewline")
@system unittest
{
    // An embedded '\n' splits a cell into lines, and sizes the column by its widest
    // line (1 here, not the newline-joined length).
    checkRender(drawTable([["a\nb", "c"]]),
        "╭───┬───╮\n" ~
        "│ a │ c │\n" ~
        "│ b │   │\n" ~
        "╰───┴───╯\n");
}

@("drawTable.wrap.maxWidthShrinks")
@system unittest
{
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;

    // maxWidth shrinks the widest columns (largest-first) until the whole table fits,
    // wrapping the trimmed content. No rendered line exceeds the cap.
    const rendered = drawTable([["aaaa", "bbbb"]], TableProps(maxWidth: 11));
    checkRender(rendered,
        "╭────┬────╮\n" ~
        "│ aa │ bb │\n" ~
        "│ aa │ bb │\n" ~
        "╰────┴────╯\n");
    foreach (l; rendered.splitLines)
        assert(l.visibleWidth <= 11);
}

@("drawTable.wrap.maxWidthParity")
@system unittest
{
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;

    // A wide table squeezed to several widths: every line stays within the cap and
    // all lines share a width (bands and rules agree even after shrink + wrap).
    string[][] cells = [
        ["Alpha", "a longer description here", "42"],
        ["Beta", "short", "7"],
    ];
    foreach (cap; [40, 30, 24, 18])
    {
        const rendered = drawTable(cells, TableProps(maxWidth: cap));
        const lines = rendered.splitLines;
        foreach (l; lines)
        {
            assert(l.visibleWidth <= cap);
            assert(l.visibleWidth == lines[0].visibleWidth);
        }
    }
}

@("drawTable.wrap.disabledByDefault")
@system unittest
{
    import std.string : splitLines;

    // With no caps a long cell expands the column (no wrapping) — one body row.
    const rendered = drawTable([["a fairly long single cell", "x"]]);
    assert(rendered.splitLines.length == 3); // top + one row + bottom
}

@("drawTable.span.colSpanHeader")
@system unittest
{
    // A colSpan-2 header wider than its two columns widens them evenly and drops the
    // top ┬ under the span (bottom keeps ┴ where the body row splits).
    checkRender(drawTable([
            [Cell("Summary", colSpan: 2)],
            [Cell("a"), Cell("b")],
        ]),
        "╭─────────╮\n" ~
        "│ Summary │\n" ~
        "│ a  │ b  │\n" ~
        "╰────┴────╯\n");
}

@("drawTable.span.colSpanNarrow")
@system unittest
{
    // A colSpan-2 cell narrower than its columns does not widen them; the top ┬ is
    // still suppressed by the span, the bottom ┴ stays.
    checkRender(drawTable([
            [Cell("hi", colSpan: 2)],
            [Cell("long"), Cell("wide")],
        ]),
        "╭─────────────╮\n" ~
        "│ hi          │\n" ~
        "│ long │ wide │\n" ~
        "╰──────┴──────╯\n");
}

@("drawTable.span.rowSpan")
@system unittest
{
    // A rowSpan-2 cell fills both bands; its right neighbour keeps the interior │ in
    // both, and the ├/┤ only notch the right column when row separators are on.
    checkRender(drawTable([
            [Cell("L", rowSpan: 2), Cell("top")],
            [Cell("bot")],
        ]),
        "╭───┬─────╮\n" ~
        "│ L │ top │\n" ~
        "│   │ bot │\n" ~
        "╰───┴─────╯\n");
}

@("drawTable.span.rowSpanWithRowSeparators")
@system unittest
{
    // With row separators, the interior rule notches around the rowSpan cell (┤ … ├
    // become │ where the span crosses), leaving its column continuous.
    checkRender(drawTable([
            [Cell("L", rowSpan: 2), Cell("top")],
            [Cell("bot")],
        ], TableProps(rowSeparators: true)),
        "╭───┬─────╮\n" ~
        "│ L │ top │\n" ~
        "│   ├─────┤\n" ~
        "│   │ bot │\n" ~
        "╰───┴─────╯\n");
}

@("drawTable.span.block")
@system unittest
{
    // A 2×2 block anchored top-left, with two single cells filling the right column
    // and a fully-split final row (no row separators, so no interior rule).
    checkRender(drawTable([
            [Cell("BB", colSpan: 2, rowSpan: 2), Cell("x")],
            [Cell("y")],
            [Cell("a"), Cell("b"), Cell("c")],
        ]),
        "╭───────┬───╮\n" ~
        "│ BB    │ x │\n" ~
        "│       │ y │\n" ~
        "│ a │ b │ c │\n" ~
        "╰───┴───┴───╯\n");
}

@("drawTable.span.raggedRows")
@system unittest
{
    // Ragged rows: a short row's missing trailing cells become implicit blanks.
    checkRender(drawTable([
            [Cell("a"), Cell("b"), Cell("c")],
            [Cell("d")],
        ]),
        "╭───┬───┬───╮\n" ~
        "│ a │ b │ c │\n" ~
        "│ d │   │   │\n" ~
        "╰───┴───┴───╯\n");
}

@("drawTable.sparse.matchesDense")
@system unittest
{
    // The same table authored sparsely renders identically to the dense form, and
    // placement order does not matter.
    const dense = drawTable([
            [Cell("Summary", colSpan: 2)],
            [Cell("a"), Cell("b")],
        ]);
    assert(drawTable([
            Placement(0, 0, "Summary", colSpan: 2),
            Placement(1, 0, "a"),
            Placement(1, 1, "b"),
        ]) == dense);
    // Reordered placements resolve the same (order-independent).
    assert(drawTable([
            Placement(1, 1, "b"),
            Placement(1, 0, "a"),
            Placement(0, 0, "Summary", colSpan: 2),
        ]) == dense);
}

@("drawTable.sparse.gapsBecomeBlanks")
@system unittest
{
    // A never-addressed slot becomes an implicit blank cell.
    checkRender(drawTable([
            Placement(0, 0, "a"),
            Placement(1, 1, "d"),
        ]),
        "╭───┬───╮\n" ~
        "│ a │   │\n" ~
        "│   │ d │\n" ~
        "╰───┴───╯\n");
}

@("drawTable.align.perColumnHorizontal")
@system unittest
{
    // Column 0 right-aligned, column 1 centered.
    checkRender(drawTable([["a", "bb"], ["ccc", "d"]],
            TableProps(columnAligns: [Align.right, Align.center])),
        "╭─────┬────╮\n" ~
        "│   a │ bb │\n" ~
        "│ ccc │ d  │\n" ~
        "╰─────┴────╯\n");
}

@("drawTable.align.shortArrayFallsBackToDefault")
@system unittest
{
    // A short columnAligns array: column 0 uses its entry, column 1 the default.
    checkRender(drawTable([["a", "bb"], ["ccc", "d"]],
            TableProps(defaultAlign: Align.right, columnAligns: [Align.left])),
        "╭─────┬────╮\n" ~
        "│ a   │ bb │\n" ~
        "│ ccc │  d │\n" ~
        "╰─────┴────╯\n");
}

@("drawTable.align.verticalBottomOnRowSpan")
@system unittest
{
    // A rowSpan cell bottom-aligned sits in its lower band.
    checkRender(drawTable([
            [Cell("M", rowSpan: 2), Cell("x")],
            [Cell("y")],
        ], TableProps(columnVAligns: [VAlign.bottom])),
        "╭───┬───╮\n" ~
        "│   │ x │\n" ~
        "│ M │ y │\n" ~
        "╰───┴───╯\n");
}

@("drawTable.align.verticalMiddleInWrappedRow")
@system unittest
{
    // A short cell middle-aligned within a row made 3 lines tall by a wrapped sibling.
    checkRender(drawTable([[Cell("a\nb\nc"), Cell("mid")]],
            TableProps(columnVAligns: [VAlign.top, VAlign.middle])),
        "╭───┬─────╮\n" ~
        "│ a │     │\n" ~
        "│ b │ mid │\n" ~
        "│ c │     │\n" ~
        "╰───┴─────╯\n");
}

@("drawTable.validate.wellFormed")
@system unittest
{
    // A well-formed table validates, in both authoring forms.
    assert(validateTable([[Cell("a"), Cell("b")], [Cell("c"), Cell("d")]]).hasValue);
    assert(validateTable([Placement(0, 0, "a"), Placement(1, 1, "b")]).hasValue);
}

@("drawTable.validate.overlap")
@system unittest
{
    // Two placements claiming the same slot is a detected overlap — but drawTable
    // still renders deterministically (first-writer-wins).
    auto placements = [
        Placement(0, 0, "A", colSpan: 2),
        Placement(0, 1, "B"), // collides with A's second column
    ];
    auto v = validateTable(placements);
    assert(v.hasError);
    assert(v.error.kind == TableErrorKind.overlap);
    assert(v.error.row == 0 && v.error.col == 1);
    // Rendering does not throw and keeps the first writer (A) in the shared slot.
    const rendered = drawTable(placements);
    assert(rendered.length > 0);
}

@("drawTable.validate.rowSpanOutOfBounds")
@system unittest
{
    // A rowspan past the last authored row is flagged and clamped.
    auto v = validateTable([[Cell("x", rowSpan: 3)], [Cell("y")]]);
    assert(v.hasError);
    assert(v.error.kind == TableErrorKind.rowSpanOutOfBounds);
    // Clamped to the two rows: renders without extra empty bands.
    import std.string : splitLines;

    assert(drawTable([[Cell("x", rowSpan: 3)], [Cell("y")]]).splitLines.length == 4);
}
