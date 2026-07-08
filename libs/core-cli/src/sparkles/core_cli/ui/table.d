module sparkles.core_cli.ui.table;

import std.array : array, appender;
import std.algorithm : map, all, maxElement, sort;
import std.algorithm.comparison : max;
import std.range : iota;

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

/// Table rendering configuration. Defaults reproduce the pre-overhaul rendering
/// byte-for-byte: rounded glyphs, column separators on, row separators off, outer
/// border on.
struct TableProps
{
    TableGlyphs glyphs;            /// Box-drawing glyph set.
    bool border           = true; /// Draw the outer frame.
    bool columnSeparators = true; /// Draw interior vertical `│` lines.
    bool rowSeparators    = false;/// Draw interior horizontal `─` rules.
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

/// `string[][]` sugar → extent-1 `Cell`-equivalent rows for the resolver.
private struct Cell
{
    string content;
    size_t colSpan = 1;
    size_t rowSpan = 1;
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
/// clamp rowspans past the last row, then fill every uncovered slot with an implicit
/// empty anchor so the grid is fully populated (always renderable).
private SlotGrid resolveGrid(in Cell[][] rows) @safe pure nothrow
{
    Anchor[] anchors;
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
            foreach (dr; 0 .. rs)
                foreach (dc; 0 .. cs)
                {
                    ensure(r + dr, c + dc);
                    if (!occ[r + dr][c + dc]) // first-writer-wins on overlap
                    {
                        occ[r + dr][c + dc] = true;
                        owner[r + dr][c + dc] = idx + 1;
                    }
                }
            numCols = max(numCols, c + cs);
            c += cs;
        }
    }

    const numRows = max(rows.length, occ.length);
    foreach (ref a; anchors) // clamp rowspans that ran past the last row
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

/// Which grid row band holds a (possibly rowspan) anchor's content. Top-align for
/// now; the seam vertical alignment slots into later.
private size_t contentBand(in Anchor a) @safe pure nothrow @nogc => a.row;

/// Per-column content widths: per-column max of extent-1 anchors (== the legacy
/// `columnWidths` base case), then grow member columns so every colspan cell fits.
private size_t[] resolveColumnWidths(in SlotGrid g, in TableProps p) @safe pure nothrow
{
    const sepW = p.columnSeparators ? 1 : 0;
    auto w = new size_t[g.numCols];
    foreach (ref a; g.anchors)
        if (a.colSpan == 1)
            w[a.col] = max(w[a.col], visibleWidth(a.content));

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
        const vw = visibleWidth(a.content);
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

/// One text line for grid row `r` (single-line bands for now): each anchor's field
/// (` <aligned-content> ` in its content band, ` <blank> ` in covered bands),
/// separated by interior verticals where a real boundary sits.
private string bodyBand(in SlotGrid g, in size_t[] w, in TableProps p, size_t r)
{
    const sepW = p.columnSeparators ? 1 : 0;
    auto line = appender!string;
    if (p.border)
        line ~= p.glyphs.verticalLine;
    size_t c = 0;
    while (c < g.numCols)
    {
        const a = g.anchors[owner(g, r, c)];
        const f = contentField(a, w, sepW);
        line ~= ' ';
        if (r == contentBand(a))
            alignField(line, a.content, f, Align.left);
        else
            foreach (_; 0 .. f)
                line ~= ' ';
        line ~= ' ';
        c += a.colSpan;
        if (c < g.numCols && vSeg(g, p, r, c))
            line ~= p.glyphs.verticalLine;
    }
    if (p.border)
        line ~= p.glyphs.verticalLine;
    line ~= '\n';
    return line[];
}

/// Render a resolved grid: top border, then each body band (with interior rules
/// between bands when `rowSeparators`), then the bottom border.
private string drawGrid(in SlotGrid g, in TableProps p)
{
    if (g.numRows == 0 || g.numCols == 0)
        return "";
    auto w = resolveColumnWidths(g, p);
    auto out_ = appender!string;
    if (p.border)
        out_ ~= separatorLine(g, w, p, 0);
    foreach (r; 0 .. g.numRows)
    {
        out_ ~= bodyBand(g, w, p, r);
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
    return drawGrid(resolveGrid(toCells(cells)), props);
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
