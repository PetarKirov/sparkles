module sparkles.ui.components.table.render;

import std.array : array, appender;
import std.algorithm : map, all, maxElement, sort;
import std.algorithm.comparison : max, min;
import std.range : iota;
import std.range.primitives : isOutputRange;
import std.typecons : Nullable, nullable;

import expected : Expected, ok, err;

import sparkles.base.text.grapheme : visibleWidth;
import sparkles.base.text.width : Align, alignField;

import sparkles.ui.components.table.grid;
import sparkles.ui.components.table.layout;


// ---------------------------------------------------------------------------
// Span-capable table model (see docs/specs/core-cli/table.md)
//
// Authoring is a dense `string[][]` (rectangular, extent-1) — the public
// `drawTable` overload below. Internally it lowers to an HTML "slot grid": every
// cell is an `Anchor` at `(row, col)` covering a `rowSpan × colSpan` rectangle,
// and coverage is *derived* (`slotOwner`), never stored. The renderer is a
// pipeline of free functions over that grid — configuration, width/height
// solving, junction logic and line ordering live in the content-agnostic
// `sparkles.ui.components.table.layout` core; this module is the STRING view:
// it measures with the grapheme-aware `visibleWidth`, wraps with
// `sparkles.base.text.wrap`, and emits ANSI-transparent text lines.
// ---------------------------------------------------------------------------


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

/// Visible width after the last visible `.` in `s` (escapes free), or
/// `size_t.max` when `s` has no dot — the ingredient of columnar decimal
/// alignment.
private size_t decimalTailWidth(string s) @safe pure
{
    import sparkles.base.text.grapheme : byGraphemeCluster;

    size_t width = 0;
    bool seen = false;
    foreach (c; s.byGraphemeCluster)
    {
        if (c.isEscape)
            continue;
        if (c.slice == ".")
        {
            seen = true;
            width = 0;
        }
        else if (seen)
            width += c.width;
    }
    return seen ? width : size_t.max;
}

/// Per-anchor `Align.decimal` trailing pads for the string view: measure each
/// anchor's decimal tail with the escape-aware `decimalTailWidth`, then let the
/// core's `decimalPadsFor` aggregate per column. Null when no column is decimal.
private size_t[] anchorDecimalPads(in SlotGrid g, in TableProps p) @safe pure
{
    bool any = false;
    foreach (c; 0 .. g.numCols)
        any = any || effectiveAlign(c, p) == Align.decimal;
    if (!any)
        return null;

    auto tails = new size_t[g.anchors.length];
    foreach (i, ref a; g.anchors)
        tails[i] = decimalTailWidth(a.content);
    return decimalPadsFor(g, p, tails);
}

/// One horizontal rule (top border, interior row separator, or bottom border) at
/// lattice row `i`: the core's `ruleGlyphs` joined to UTF-8.
private string separatorLine(in SlotGrid g, in size_t[] w, in TableProps p, size_t i)
{
    import std.conv : to;

    return ruleGlyphs(g, p, w, i).to!string;
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

    auto result = new string[][](g.anchors.length);
    foreach (i, ref a; g.anchors)
    {
        const f = contentField(a, w, p, g.numCols);
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


/// One streamable segment of a body line: `frame` bytes (left border, gutters,
/// interior separators) followed by an aligned cell `field`. `contentful` marks
/// fields carrying visible content — blank filler fields (out-of-band rowspan
/// rows, empty cells) count as frame for chunking purposes. The line-closing
/// right frame is a final field-less segment. Concatenating `frame ~ field`
/// over all segments reproduces the body line byte-for-byte (`bodyLine` is
/// exactly that join, so the two cannot drift).
private struct LineSegment
{
    string frame;
    string field;
    bool contentful;
}

/// Decompose text line `t` of grid row `r` (`t < lay.rowHeights[r]`) into
/// segments: each anchor emits its wrapped line for the current text line in
/// its content band, or a blank field otherwise, separated by interior
/// verticals where a real boundary sits. No trailing newline.
private LineSegment[] bodyLineSegments(in TableLayout lay, size_t r, size_t t)
{
    const g = lay.grid;
    const p = lay.props;
    LineSegment[] segs;
    auto frame = appender!string;
    if (p.border)
        frame ~= p.glyphs.verticalLine;
    size_t c = 0;
    while (c < g.numCols)
    {
        const idx = owner(lay.grid, r, c);
        const a = g.anchors[idx];
        const f = contentField(a, lay.widths, p, g.numCols);
        // This anchor's line index at row r, text line t: the sum of the heights
        // of its bands above r, plus t. For an extent-1 cell that is just t; a
        // rowspan cell's content flows down across its stacked bands.
        size_t li = t;
        foreach (rr; a.row .. r)
            li += lay.rowHeights[rr];
        // Vertical alignment shifts the content block down within the anchor's
        // combined height; horizontal alignment is applied per line.
        size_t hh = 0;
        foreach (rr; a.row .. a.row + a.rowSpan)
            hh += lay.rowHeights[rr];
        const top = padTop(hh, lay.cellLines[idx].length, anchorVAlign(a, p));
        frame ~= ' ';

        auto field = appender!string;
        bool contentful = false;
        if (li >= top && li - top < lay.cellLines[idx].length)
        {
            contentful = lay.cellLines[idx][li - top].length != 0;
            // A decimal column's trailing pad shifts the right-aligned value
            // left so every dot in the column shares a cell.
            const dpad = lay.decimalPads.length ? lay.decimalPads[idx] : 0;
            if (dpad > 0 && dpad < f)
            {
                alignField(field, lay.cellLines[idx][li - top], f - dpad, Align.right);
                foreach (_; 0 .. dpad)
                    field ~= ' ';
            }
            else
                alignField(field, lay.cellLines[idx][li - top], f, anchorAlign(a, p));
        }
        else
            foreach (_; 0 .. f)
                field ~= ' ';
        segs ~= LineSegment(frame[], field[], contentful);

        frame = appender!string;
        frame ~= ' '; // the gutter after the field
        c += a.colSpan;
        if (c < g.numCols && vSeg(lay.grid, p, r, c))
            frame ~= isHeaderCol(p, c, g.numCols)
                ? p.glyphs.headerCol.verticalLine : p.glyphs.verticalLine;
    }
    if (p.border)
        frame ~= p.glyphs.verticalLine;
    segs ~= LineSegment(frame[], "", false); // the closing right frame
    return segs;
}

/// Render text line `t` of grid row `r`: the join of its segments. No trailing
/// newline — emission joins lines (see `lineDescs`/`renderLine`).
private string bodyLine(in TableLayout lay, size_t r, size_t t)
{
    auto out_ = appender!string;
    foreach (seg; bodyLineSegments(lay, r, t))
    {
        out_ ~= seg.frame;
        out_ ~= seg.field;
    }
    return out_[];
}

/// Splice `label`, wrapped in the title decorations, into a border `rule` (a
/// bare line, no newline): `╭──╼ Label ╾─┬──╮`. The label is truncated with `…`
/// when the rule is too narrow; junction glyphs under the label are simply
/// covered (the same policy as `drawBox`, whose title also interrupts its top
/// rule). `label` may be styled — it is measured by visible width and spliced
/// opaquely between plain-`dchar` border runs.
private string spliceIntoRule(string rule, string label, in TableProps p)
{
    import std.conv : to;
    import sparkles.base.text.width : truncateField;

    auto chars = rule.to!(dchar[]); // border glyphs are 1 cell each
    enum lead = 3;         // corner + two fill cells before the decoration
    enum decoration = 4;   // prefix + space … space + suffix
    enum trail = 2;        // at least one fill cell + the closing corner
    if (chars.length < lead + decoration + 1 + trail)
        return rule; // too narrow for any label; keep the plain border

    const maxLabel = chars.length - lead - decoration - trail;
    const clamped = truncateField(label, maxLabel);
    const labelWidth = visibleWidth(clamped);

    auto out_ = appender!string;
    out_ ~= chars[0 .. lead].to!string;
    out_ ~= p.glyphs.titlePrefix;
    out_ ~= ' ';
    out_ ~= clamped;
    out_ ~= ' ';
    out_ ~= p.glyphs.titleSuffix;
    out_ ~= chars[lead + decoration + labelWidth .. $].to!string;
    return out_[];
}

/// The fully-resolved layout of one table: the grid plus everything the
/// emission stage needs, computed once ("eager layout") so that line/chunk
/// production can be lazy. Shared by the eager `drawGrid` and the streaming
/// views, which therefore cannot drift.
package(sparkles.ui.components.table) struct TableLayout
{
    SlotGrid grid;
    TableProps props;
    size_t[] decimalPads;   /// per-anchor `Align.decimal` trailing pads
    size_t[] widths;        /// per-column content widths
    string[][] cellLines;   /// per-anchor wrapped content lines
    size_t[] rowHeights;    /// per grid-row text height
}

/// Resolve `g` under `p` into a $(LREF TableLayout).
package(sparkles.ui.components.table) TableLayout computeTableLayout(
    SlotGrid g, TableProps p)
{
    auto decimalPads = anchorDecimalPads(g, p);
    auto naturals = new size_t[g.anchors.length];
    foreach (i, ref a; g.anchors)
        naturals[i] = naturalWidth(a.content);
    auto widths = resolveColumnWidths(g, p, naturals, decimalPads);
    auto cellLines = wrapCells(g, widths, p);
    auto lineCounts = new size_t[g.anchors.length];
    foreach (i, lines; cellLines)
        lineCounts[i] = lines.length;
    auto rowHeights = resolveRowHeights(g, lineCounts);
    return TableLayout(g, p, decimalPads, widths, cellLines, rowHeights);
}


/// Render one described line (no trailing newline).
private string renderLine(in TableLayout lay, in LineDesc d)
{
    const p = lay.props;
    final switch (d.kind)
    {
        case LineKind.topRule:
            auto top = separatorLine(lay.grid, lay.widths, p, 0);
            return p.title.length ? spliceIntoRule(top, p.title, p) : top;
        case LineKind.titlePlain:
            return p.title;
        case LineKind.body:
            return bodyLine(lay, d.r, d.t);
        case LineKind.rule:
            return separatorLine(lay.grid, lay.widths, p, d.r);
        case LineKind.bottomRule:
            auto bottom = separatorLine(lay.grid, lay.widths, p, lay.grid.numRows);
            return p.footer.length ? spliceIntoRule(bottom, p.footer, p) : bottom;
        case LineKind.footerPlain:
            return p.footer;
    }
}

/// Render a resolved grid eagerly: walk the line descriptors and join with
/// newlines (every line, including the last, is terminated — drawTable's
/// historical shape).
private string drawGrid(SlotGrid g, TableProps p)
{
    auto lay = computeTableLayout(g, p);
    auto out_ = appender!string;
    foreach (d; lineDescs(lay.grid, lay.props, lay.rowHeights))
    {
        out_ ~= renderLine(lay, d);
        out_ ~= '\n';
    }
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

/// The lazy line view of `drawTable`: **eager layout, lazy emission**. Table
/// layout is two-pass (column widths scan all content), so unlike the
/// fixed-width `drawBox` case the input can never be consumed lazily; what is
/// lazy is emission — each rule / body text line is built on demand from the
/// resolved layout.
///
/// A *forward* range of `string` lines **without** trailing newlines (ready for
/// `LiveRegion.update`), with `.length`. Parity:
/// `drawTableLines(c, p).map!(l => l ~ '\n').join == drawTable(c, p)`
/// byte-for-byte (drawTable terminates every line, including the last), i.e.
/// `drawTableLines(c, p).array == drawTable(c, p).splitLines`. An empty grid is
/// an empty range (drawTable's historical `""`).
auto drawTableLines(string[][] cells, TableProps props = TableProps.init)
in (hasRectangularShape(cells))
{
    return tableLineRange(resolveGrid(toCells(cells)).grid, props);
}

/// ditto
auto drawTableLines(Cell[][] cells, TableProps props = TableProps.init)
{
    return tableLineRange(resolveGrid(cells).grid, props);
}

/// ditto
auto drawTableLines(Placement[] cells, TableProps props = TableProps.init)
{
    return tableLineRange(resolveGrid(cells).grid, props);
}

/// ditto
private TableLineRange tableLineRange(SlotGrid g, TableProps p)
{
    auto lay = computeTableLayout(g, p);
    return TableLineRange(lay, lineDescs(lay.grid, lay.props, lay.rowHeights));
}

/// The range type of $(LREF drawTableLines). All state is value cursors over
/// the immutable resolved layout, so `save` is a struct copy — usable twice
/// (e.g. a `LiveRegion` re-render).
struct TableLineRange
{
    private TableLayout _lay;
    private LineDesc[] _descs;
    private size_t _i;

    /// Forward-range primitives.
    bool empty() const @safe pure nothrow @nogc => _i >= _descs.length;

    /// ditto
    string front() const
    in (!empty)
        => renderLine(_lay, _descs[_i]);

    /// ditto
    void popFront() @safe pure nothrow @nogc
    in (!empty)
    {
        _i++;
    }

    /// ditto
    TableLineRange save() @safe pure nothrow @nogc => this;

    /// Remaining line count (cheap: the descriptors are precomputed).
    size_t length() const @safe pure nothrow @nogc => _descs.length - _i;
}

/// Output-range form: put exactly `drawTable`'s bytes into `w` (a composition
/// convenience — internals still allocate during layout; this is not a `@nogc`
/// path). Returns `w` for chaining.
ref Writer drawTable(Writer)(return ref Writer w, string[][] cells,
    TableProps props = TableProps.init)
if (isOutputRange!(Writer, char))
in (hasRectangularShape(cells))
{
    return putTable(w, tableLineRange(resolveGrid(toCells(cells)).grid, props));
}

/// ditto
ref Writer drawTable(Writer)(return ref Writer w, Cell[][] cells,
    TableProps props = TableProps.init)
if (isOutputRange!(Writer, char))
{
    return putTable(w, tableLineRange(resolveGrid(cells).grid, props));
}

/// ditto
ref Writer drawTable(Writer)(return ref Writer w, Placement[] cells,
    TableProps props = TableProps.init)
if (isOutputRange!(Writer, char))
{
    return putTable(w, tableLineRange(resolveGrid(cells).grid, props));
}

// ── screen ↔ cell mapping (hue `TBL3`) ────────────────────────────────────────

/// A grid cell under a point, plus the byte offset within that cell's content.
struct GridHit
{
    size_t row;        /// grid row of the covering cell
    size_t col;        /// grid column of the covering cell
    size_t charInCell; /// byte offset into `TableGridMap.cellText(row, col)`
}

/// One on-screen extent `[xStart, xEnd)` (columns from the table's left edge) on
/// output line `line` — a whole cell, or a sub-range of one.
struct CellSpan
{
    size_t line, xStart, xEnd;
}

/// A visible content field: the on-screen placement of one (wrapped) content line
/// of a cell, and where it maps in the cell's content.
private struct MapField
{
    size_t line, row, col, xStart, width, charBase;
    Align align_;
    string text; // the wrapped content line shown in this field
}

/// Screen ↔ grid-cell mapping for a rendered table (hue `TBL3`): map a click to a
/// cell + character, a cell (or a character range) to its on-screen rects, and
/// read a cell's text. Built by $(LREF drawTableMapped) from the renderer's own
/// layout, so its coordinates line up with the emitted `lines` exactly (`x` is a
/// column from the table's left edge; `line` indexes the emitted lines).
struct TableGridMap
{
    private size_t _rows, _cols;
    private MapField[] _fields;
    private string[] _cellText; // [r*_cols + c]

    /// Grid dimensions.
    size_t numRows() const @safe pure nothrow @nogc => _rows;
    size_t numCols() const @safe pure nothrow @nogc => _cols; /// ditto

    /// The raw text of cell `(row, col)` (the covering anchor's content).
    string cellText(size_t row, size_t col) const @safe pure nothrow @nogc
        => (row < _rows && col < _cols) ? _cellText[row * _cols + col] : null;

    /// The cell (and char offset) under output line `line`, screen column `x` —
    /// null on a border / gutter / outside any cell.
    Nullable!GridHit hit(size_t line, size_t x) const @safe
    {
        foreach (ref f; _fields)
        {
            if (f.line != line || x < f.xStart || x >= f.xStart + f.width)
                continue;
            const inField = x - f.xStart;
            const lead = leadPad(f.width, visibleWidth(f.text), f.align_);
            const w = visibleWidth(f.text);
            const contentCol = inField < lead ? 0
                : (inField - lead > w ? w : inField - lead);
            return nullable(GridHit(f.row, f.col, f.charBase + columnToByte(f.text, contentCol)));
        }
        return Nullable!GridHit.init;
    }

    /// Every on-screen rect of cell `(row, col)` (several if it wraps).
    CellSpan[] cellSpans(size_t row, size_t col) const @safe
    {
        CellSpan[] r;
        foreach (ref f; _fields)
            if (f.row == row && f.col == col)
                r ~= CellSpan(f.line, f.xStart, f.xStart + f.width);
        return r;
    }

    /// The on-screen rects covering byte range `[lo, hi)` of cell `(row, col)`'s
    /// content — for sub-cell highlight; clipped per wrapped line.
    CellSpan[] charSpans(size_t row, size_t col, size_t lo, size_t hi) const @safe
    {
        CellSpan[] r;
        foreach (ref f; _fields)
        {
            if (f.row != row || f.col != col)
                continue;
            const lineLo = f.charBase, lineHi = f.charBase + f.text.length;
            const a = lo > lineLo ? lo : lineLo;
            const b = hi < lineHi ? hi : lineHi;
            if (a >= b)
                continue;
            const lead = leadPad(f.width, visibleWidth(f.text), f.align_);
            const c0 = f.xStart + lead + byteToColumn(f.text, a - f.charBase);
            const c1 = f.xStart + lead + byteToColumn(f.text, b - f.charBase);
            if (c1 > c0)
                r ~= CellSpan(f.line, c0, c1);
        }
        return r;
    }
}

/// A rendered table plus its screen↔cell map (hue `TBL3`).
struct MappedTable
{
    string[] lines;
    TableGridMap map;
}

/// Render `cells` and return the lines together with a $(LREF TableGridMap) for
/// screen↔cell hit-testing (the GUI's table selection). Layout is identical to
/// $(LREF drawTableLines); only the map is extra.
MappedTable drawTableMapped(string[][] cells, TableProps props = TableProps.init)
in (hasRectangularShape(cells))
{
    return buildMappedTable(computeTableLayout(resolveGrid(toCells(cells)).grid, props), props);
}

private MappedTable buildMappedTable(in TableLayout lay, in TableProps p)
{
    const g = lay.grid;
    string[] lines;
    foreach (d; lineDescs(lay.grid, lay.props, lay.rowHeights))
        lines ~= renderLine(lay, d);

    // The map's fields derive from the core's one body-line walk (the same
    // placement the widget view positions from), so the recorded `xStart`
    // matches the emitted line byte-for-byte; only the byte-offset bookkeeping
    // (`charBase`) is string-view business.
    auto lineCounts = new size_t[g.anchors.length];
    foreach (i, cellLines; lay.cellLines)
        lineCounts[i] = cellLines.length;
    MapField[] fields;
    foreach (ref fp; walkBodyLines(g, p, lay.widths, lay.rowHeights, lineCounts).fields)
    {
        if (!fp.hasContent)
            continue;
        const a = g.anchors[fp.anchor];
        size_t charBase;
        foreach (j; 0 .. fp.lineInCell)
            charBase += lay.cellLines[fp.anchor][j].length;
        fields ~= MapField(fp.line, a.row, a.col, fp.x, fp.width, charBase,
            anchorAlign(a, p), lay.cellLines[fp.anchor][fp.lineInCell]);
    }

    auto cellText = new string[g.numRows * g.numCols];
    foreach (r; 0 .. g.numRows)
        foreach (c; 0 .. g.numCols)
            cellText[r * g.numCols + c] = g.anchors[owner(g, r, c)].content;
    return MappedTable(lines, TableGridMap(g.numRows, g.numCols, fields, cellText));
}


/// Byte offset in `s` at display column `col` (clamped to `s.length`).
private size_t columnToByte(string s, size_t col) @safe
{
    import std.utf : decode;
    import std.typecons : Yes;

    size_t i, w;
    while (i < s.length && w < col)
    {
        const start = i;
        decode!(Yes.useReplacementDchar)(s, i);
        w += visibleWidth(s[start .. i]);
    }
    return i;
}

/// Display column at byte offset `b` in `s`.
private size_t byteToColumn(string s, size_t b) @safe
{
    if (b > s.length)
        b = s.length;
    return visibleWidth(s[0 .. b]);
}

private ref Writer putTable(Writer)(return ref Writer w, TableLineRange lines)
{
    import std.range.primitives : put;

    foreach (line; lines)
    {
        put(w, line);
        put(w, '\n');
    }
    return w;
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

@("drawTable.separators.headerRows")
@system unittest
{
    // headerRows: 1 draws a distinct (heavy) rule after the first row only — no
    // other interior rules, and the header glyphs (┝━┿━┥) stand apart from the frame.
    checkRender(drawTable([["ab", "c"], ["d", "ef"], ["g", "hi"]], TableProps(headerRows: 1)),
        "╭────┬────╮\n" ~
        "│ ab │ c  │\n" ~
        "┝━━━━┿━━━━┥\n" ~
        "│ d  │ ef │\n" ~
        "│ g  │ hi │\n" ~
        "╰────┴────╯\n");
}

@("drawTable.separators.headerCols")
@system unittest
{
    // headerCols: 1 with column separators off draws only the stub rule (heavy
    // vertical ┃, ┰/┸ ticks on the frame), width-budgeted so parity holds.
    checkRender(drawTable([["ab", "c"], ["d", "ef"]],
            TableProps(headerCols: 1, columnSeparators: false)),
        "╭────┰────╮\n" ~
        "│ ab ┃ c  │\n" ~
        "│ d  ┃ ef │\n" ~
        "╰────┸────╯\n");
}

@("drawTable.separators.headerColsWithColumnSeparators")
@system unittest
{
    // With column separators on, the stub boundary (after col 0) is heavy while the
    // remaining interior boundary stays light.
    checkRender(drawTable([["a", "b", "c"], ["d", "e", "f"]], TableProps(headerCols: 1)),
        "╭───┰───┬───╮\n" ~
        "│ a ┃ b │ c │\n" ~
        "│ d ┃ e │ f │\n" ~
        "╰───┸───┴───╯\n");
}

@("drawTable.separators.headerRowAndColCross")
@system unittest
{
    // Header row and stub column together: the crossing junction is the heavy-both
    // cross ╋, with heavy arms in each axis (┝/┥ ends, ┃ stub, ━ header fill).
    checkRender(drawTable([["ab", "c"], ["d", "ef"]],
            TableProps(headerRows: 1, headerCols: 1)),
        "╭────┰────╮\n" ~
        "│ ab ┃ c  │\n" ~
        "┝━━━━╋━━━━┥\n" ~
        "│ d  ┃ ef │\n" ~
        "╰────┸────╯\n");
}

@("drawTable.separators.headerMultiRowMultiCol")
@system unittest
{
    // headerRows: 2 / headerCols: 2 place the rules after the second row / column.
    checkRender(drawTable([["a", "b", "c"], ["d", "e", "f"], ["g", "h", "i"]],
            TableProps(headerRows: 2, headerCols: 2)),
        "╭───┬───┰───╮\n" ~
        "│ a │ b ┃ c │\n" ~
        "│ d │ e ┃ f │\n" ~
        "┝━━━┿━━━╋━━━┥\n" ~
        "│ g │ h ┃ i │\n" ~
        "╰───┴───┸───╯\n");
}

@("drawTable.separators.headerWithRowSeparators")
@system unittest
{
    // The header rule stays heavy (┝━┿━┥) even amid light ├─┼─┤ row separators.
    checkRender(drawTable([["ab", "c"], ["d", "ef"], ["g", "hi"]],
            TableProps(headerRows: 1, rowSeparators: true)),
        "╭────┬────╮\n" ~
        "│ ab │ c  │\n" ~
        "┝━━━━┿━━━━┥\n" ~
        "│ d  │ ef │\n" ~
        "├────┼────┤\n" ~
        "│ g  │ hi │\n" ~
        "╰────┴────╯\n");
}

@("drawTable.separators.headerAsciiPreset")
@system unittest
{
    // The ascii preset uses the '===' convention for its header rule.
    checkRender(drawTable([["ab", "c"], ["d", "ef"]],
            TableProps(glyphs: stylePresets["ascii"], headerRows: 1)),
        "+----+----+\n" ~
        "| ab | c  |\n" ~
        "+====+====+\n" ~
        "| d  | ef |\n" ~
        "+----+----+\n");
}

@("drawTable.separators.headerOutOfRange")
@system unittest
{
    // headerRows / headerCols at or past the table dimensions are silent no-ops
    // (the rule would coincide with the bottom/right border), so the render equals
    // the default one.
    string[][] cells = [["ab", "c"], ["d", "ef"]];
    const base = drawTable(cells);
    assert(drawTable(cells, TableProps(headerRows: 2)) == base);
    assert(drawTable(cells, TableProps(headerRows: 9)) == base);
    assert(drawTable(cells, TableProps(headerCols: 2)) == base);
    assert(drawTable(cells, TableProps(headerCols: 9)) == base);
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

    // Bands and rules must share a width in every toggle combination, including the
    // header-row / stub-column emphasis rules (a stub rule inserts a lattice column
    // even with column separators off, so its width must be budgeted).
    string[][] cells = [["ab", "c", "xyz"], ["d", "ef", "g"]];
    foreach (border; [false, true])
        foreach (colSep; [false, true])
            foreach (rowSep; [false, true])
                foreach (hRows; [0UL, 1UL])
                    foreach (hCols; [0UL, 1UL])
                    {
                        const rendered = drawTable(cells, TableProps(
                            border: border, columnSeparators: colSep, rowSeparators: rowSep,
                            headerRows: hRows, headerCols: hCols));
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

@("drawTable.width.columnMinWidths")
@system unittest
{
    // A floor widens a narrow column (content aligns into the wider field);
    // natural width above the floor is untouched, and a short array leaves the
    // remaining columns natural.
    checkRender(drawTable([["a", "b"]], TableProps(columnMinWidths: [5])),
        "╭───────┬───╮\n" ~
        "│ a     │ b │\n" ~
        "╰───────┴───╯\n");
    assert(drawTable([["abcdef", "b"]], TableProps(columnMinWidths: [3]))
        == drawTable([["abcdef", "b"]]));

    // The floor keeps a live table's geometry stable: rendering the early rows
    // under the final widths matches the final table's column layout.
    const wide = drawTable([["regex 200 e-mails", "1"]]);
    const early = drawTable([["sort", "1"]],
        TableProps(columnMinWidths: [17, 0]));
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;
    assert(early.splitLines[0].visibleWidth == wide.splitLines[0].visibleWidth);
}

@("drawTable.width.columnMinWidthsCapsStillWin")
@system unittest
{
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;

    // A columnMaxWidths entry below the floor still caps the column.
    checkRender(drawTable([["ab"]],
            TableProps(columnMinWidths: [8], columnMaxWidths: [4])),
        "╭──────╮\n" ~
        "│ ab   │\n" ~
        "╰──────╯\n");

    // The total maxWidth shrink also beats the floor, so fit-to-width holds.
    const rendered = drawTable([["ab"]],
        TableProps(columnMinWidths: [10], maxWidth: 9));
    foreach (l; rendered.splitLines)
        assert(l.visibleWidth == 9);
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

@("drawTable.validate.allErrors")
@safe unittest
{
    // One overlap (c's colspan extends into b's rowspan-covered slot) + one
    // out-of-bounds rowspan (d past the last authored row): validateTable
    // reports only the first, validateTableAll both.
    auto cells = [
        [Cell("a"), Cell("b", rowSpan: 2)],
        [Cell("c", colSpan: 2), Cell("d", rowSpan: 3)],
    ];
    assert(validateTable(cells).hasError);
    const all = validateTableAll(cells);
    assert(all.length == 2);
    assert(all[0].kind == TableErrorKind.overlap);
    assert(all[1].kind == TableErrorKind.rowSpanOutOfBounds);

    assert(validateTableAll([[Cell("x")]]).length == 0);
}

@("drawTable.title.splicedIntoTopBorder")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    checkRender(drawTable([["alpha", "beta"], ["1", "2"]],
        TableProps(title: "T")), `
        ╭──╼ T ╾┬──────╮
        │ alpha │ beta │
        │ 1     │ 2    │
        ╰───────┴──────╯
        `.outdent(2));
}

@("drawTable.titleFooter.truncateAndAscii")
@system unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;

    // A title wider than the table truncates with '…' instead of widening the
    // frame; every line keeps the same width, and the footer is spliced with
    // the same decorations.
    const t = drawTable([["alpha", "beta"]],
        TableProps(title: "a very long table title", footer: "f"));
    const lines = t.splitLines;
    assert(lines[0].canFind("…"));
    assert(lines[$ - 1].canFind("╼ f ╾"));
    foreach (line; lines)
        assert(line.visibleWidth == lines[0].visibleWidth);

    // The ascii preset swaps the decorations to [ ] (a frame narrower than
    // the decorations keeps its plain border, so use wide-enough cells).
    const ascii = drawTable([["alpha", "beta"]],
        TableProps(title: "T", glyphs: presetGlyphs("ascii")));
    assert(ascii.splitLines[0].startsWith("+--[ T ]"));
}

@("drawTable.titleFooter.borderlessDegradesToPlainLines")
@system unittest
{
    import std.string : splitLines;

    const t = drawTable([["a", "b"]],
        TableProps(title: "Title", footer: "Footer", border: false));
    // The body row keeps its right gutter (a trailing space), so compare per
    // line rather than via an outdented literal.
    assert(t.splitLines == ["Title", " a │ b ", "Footer"]);
}

@("drawTable.align.decimalColumn")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // Dots share a cell; the dotless value's last digit sits just left of the
    // dot column; the header (row 0) right-aligns plainly, exempt from padding.
    checkRender(drawTable([["n", "value"], ["a", "1.5"], ["b", "12.25"], ["c", "3"]],
        TableProps(headerRows: 1,
            columnAligns: [Align.left, Align.decimal])), `
        ╭───┬───────╮
        │ n │ value │
        ┝━━━┿━━━━━━━┥
        │ a │  1.5  │
        │ b │ 12.25 │
        │ c │  3    │
        ╰───┴───────╯
        `.outdent(2));
}

@("drawTable.align.decimalWithoutDotsIsRight")
@system unittest
{
    // No dotted value in the column -> decimal degrades to plain right.
    const t = drawTable([["1", "22"], ["333", "4"]],
        TableProps(columnAligns: [Align.decimal, Align.decimal]));
    const plain = drawTable([["1", "22"], ["333", "4"]],
        TableProps(columnAligns: [Align.right, Align.right]));
    assert(t == plain);
}

@("drawTable.lines.joinEqualsString")
@system unittest
{
    import std.algorithm.iteration : joiner, map;
    import std.array : array;
    import std.conv : to;
    import std.string : splitLines;

    // The parity matrix: every layout feature the eager renderer covers.
    static void checkParity(T)(T cells, TableProps props)
    {
        const eager = drawTable(cells, props);
        auto range = drawTableLines(cells, props);
        assert(range.map!(l => l ~ '\n').joiner.to!string == eager);
        assert(drawTableLines(cells, props).array == eager.splitLines);
        assert(drawTableLines(cells, props).length == eager.splitLines.length);
    }

    checkParity([["a", "bb"], ["ccc", "d"]], TableProps.init);
    checkParity([["a", "bb"], ["ccc", "d"]], TableProps(rowSeparators: true));
    checkParity([["h1", "h2"], ["a", "b"]], TableProps(headerRows: 1, headerCols: 1));
    checkParity([["a", "b"]], TableProps(border: false));
    checkParity([["alpha", "beta"], ["1", "2"]],
        TableProps(title: "Title", footer: "Foot"));
    checkParity([["a", "b"]], TableProps(title: "T", footer: "F", border: false));
    checkParity([["a long wrapping cell content here", "x"]],
        TableProps(maxWidth: 18));
    checkParity([["alpha", "beta"], ["1", "2"]],
        TableProps(columnMaxWidths: [3, 0]));
    checkParity([["a", "b"], ["c", "d"]],
        TableProps(columnMinWidths: [6, 0]));
    checkParity([[Cell("span", colSpan: 2)], [Cell("a"), Cell("b")]], TableProps.init);
    checkParity([[Cell("tall", rowSpan: 2), Cell("x")], [Cell("y")]],
        TableProps(rowSeparators: true));
    checkParity([["n", "value"], ["a", "1.5"], ["b", "12.25"]],
        TableProps(headerRows: 1, columnAligns: [Align.left, Align.decimal]));
    checkParity([
        Placement(0, 0, "A", colSpan: 2),
        Placement(1, 1, "B"),
    ], TableProps.init);

    // Empty grid: drawTable's historical "" -> an empty range.
    string[][] none;
    assert(drawTable(none) == "");
    assert(drawTableLines(none).empty);
}

@("drawTable.lines.forwardRangeSave")
@system unittest
{
    import std.array : array;

    auto lines = drawTableLines([["a", "b"], ["c", "d"]],
        TableProps(title: "T"));
    auto saved = lines.save;
    const first = lines.array;
    const second = saved.array; // the saved copy traverses independently
    assert(first == second);
    assert(first.length == 4);
}

@("drawTable.writer.matchesString")
@system unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    static void checkWriterParity(T)(T cells, TableProps props)
    {
        SmallBuffer!(char, 1024) w;
        drawTable(w, cells, props);
        assert(w[] == drawTable(cells, props));
    }

    checkWriterParity([["a", "bb"], ["ccc", "d"]], TableProps.init);
    checkWriterParity([["alpha", "beta"], ["1", "2"]],
        TableProps(title: "Title", footer: "Foot", headerRows: 1));
    checkWriterParity([[Cell("span", colSpan: 2)], [Cell("a"), Cell("b")]],
        TableProps.init);
    checkWriterParity([Placement(0, 0, "A", colSpan: 2), Placement(1, 1, "B")],
        TableProps.init);

    // Returns the writer by ref for chaining.
    SmallBuffer!(char, 256) w;
    drawTable(w, [["x"]]).put("tail");
    assert(w[] == drawTable([["x"]]) ~ "tail");
}

/// The chunk view of `drawTable` (the sibling of `drawBoxChunks`): chunks carry
/// their own newlines and `join("")` reproduces `drawTable` byte-for-byte.
///
/// `lineBuffered: true` yields one chunk per rendered body text line (line +
/// `'\n'`); `lineBuffered: false` yields one chunk per *contentful cell field*
/// (the aligned ` content pad ` run), so pacing the output reveals the table
/// cell by cell in reading order. Frame pieces — borders, junction rules
/// (including a spliced title/footer), separators, blank filler fields — never
/// form a standalone chunk: they accumulate as a pending prefix merged onto the
/// next content chunk, and the trailing frame (closing border, bottom rule) is
/// appended to the final content chunk. A table with no content at all
/// degrades to a single chunk carrying the whole frame.
auto drawTableChunks(bool lineBuffered = true)(
    string[][] cells, TableProps props = TableProps.init)
in (hasRectangularShape(cells))
{
    return tableChunkRange!lineBuffered(resolveGrid(toCells(cells)).grid, props);
}

/// ditto
auto drawTableChunks(bool lineBuffered = true)(
    Cell[][] cells, TableProps props = TableProps.init)
{
    return tableChunkRange!lineBuffered(resolveGrid(cells).grid, props);
}

/// ditto
auto drawTableChunks(bool lineBuffered = true)(
    Placement[] cells, TableProps props = TableProps.init)
{
    return tableChunkRange!lineBuffered(resolveGrid(cells).grid, props);
}

private auto tableChunkRange(bool lineBuffered)(SlotGrid g, TableProps p)
{
    auto lay = computeTableLayout(g, p);
    return TableChunkRange!lineBuffered(lay, lineDescs(lay.grid, lay.props, lay.rowHeights));
}

/// The input range returned by $(LREF drawTableChunks). One-chunk lookahead so
/// the trailing frame attaches to the last content chunk; `front` is owned.
private struct TableChunkRange(bool lineBuffered)
{
    private
    {
        TableLayout _lay;
        LineDesc[] _descs;
        size_t _di;
        string _pending;   // frame bytes awaiting a content chunk
        string _la;        // one-chunk lookahead
        bool _laValid;
        string _front;
        bool _empty, _finished;

        static if (!lineBuffered)
        {
            LineSegment[] _segs; // current body line's segments
            size_t _si;
            bool _inBody;
        }
    }

    this(TableLayout lay, LineDesc[] descs)
    {
        _lay = lay;
        _descs = descs;
        popFront(); // prime `_front`
    }

    /// Range primitives (input range).
    bool empty() const @safe pure nothrow @nogc => _empty;

    /// ditto
    string front() const @safe pure nothrow @nogc => _front;

    /// ditto
    void popFront()
    {
        if (_finished)
        {
            _empty = true;
            return;
        }
        if (!_laValid)
        {
            if (!nextContentChunk(_la))
            {
                // No content at all: the whole frame is one chunk (or nothing
                // for an empty table).
                _front = _pending;
                _pending = null;
                _finished = true;
                _empty = _front.length == 0;
                return;
            }
            _laValid = true;
        }
        string next;
        if (nextContentChunk(next))
        {
            _front = _la;
            _la = next;
        }
        else
        {
            // `_la` was the last content chunk: the trailing frame rides on it.
            _front = _la ~ _pending;
            _pending = null;
            _finished = true;
        }
    }

    // The next pending-prefixed content chunk; false when the walk is done
    // (leftover frame stays in `_pending` for the caller to attach).
    private bool nextContentChunk(out string chunk)
    {
        for (;;)
        {
            static if (!lineBuffered)
            {
                if (_inBody)
                {
                    if (_si < _segs.length)
                    {
                        const seg = _segs[_si++];
                        _pending ~= seg.frame;
                        if (seg.contentful)
                        {
                            chunk = _pending ~ seg.field;
                            _pending = null;
                            return true;
                        }
                        _pending ~= seg.field;
                        continue;
                    }
                    _pending ~= "\n"; // the body line's terminator
                    _inBody = false;
                }
            }
            if (_di >= _descs.length)
                return false;
            const d = _descs[_di++];
            if (d.kind == LineKind.body)
            {
                static if (lineBuffered)
                {
                    chunk = _pending ~ renderLine(_lay, d) ~ "\n";
                    _pending = null;
                    return true;
                }
                else
                {
                    _segs = bodyLineSegments(_lay, d.r, d.t);
                    _si = 0;
                    _inBody = true;
                }
            }
            else
                _pending ~= renderLine(_lay, d) ~ "\n"; // rules/titles are frame
        }
    }
}

@("drawTable.chunks.joinEqualsString")
@system unittest
{
    import std.algorithm.iteration : joiner;
    import std.conv : to;

    static void checkChunksParity(T)(T cells, TableProps props)
    {
        const eager = drawTable(cells, props);
        assert(drawTableChunks!true(cells, props).joiner.to!string == eager);
        assert(drawTableChunks!false(cells, props).joiner.to!string == eager);
    }

    checkChunksParity([["a", "bb"], ["ccc", "d"]], TableProps.init);
    checkChunksParity([["h1", "h2"], ["a", "b"]],
        TableProps(headerRows: 1, rowSeparators: true));
    checkChunksParity([["alpha", "beta"], ["1", "2"]],
        TableProps(title: "Title", footer: "Foot"));
    checkChunksParity([["a", "b"]], TableProps(border: false));
    checkChunksParity([[Cell("span", colSpan: 2)], [Cell("a"), Cell("b")]],
        TableProps.init);
    checkChunksParity([[Cell("tall", rowSpan: 2), Cell("x")], [Cell("y")]],
        TableProps.init);
    checkChunksParity([["long wrapping content", "x"]], TableProps(maxWidth: 14));
    checkChunksParity([["a", "b"]], TableProps(columnMinWidths: [6, 4]));
    checkChunksParity([Placement(0, 0, "A", colSpan: 2), Placement(1, 1, "B")],
        TableProps.init);

    // Empty table: empty chunk range.
    string[][] none;
    assert(drawTableChunks!true(none).empty);
    assert(drawTableChunks!false(none).empty);
}

@("drawTable.chunks.cellGranularOrdering")
@system unittest
{
    import std.algorithm.searching : canFind, countUntil;
    import std.array : array;

    // Cell contents appear in reading order, one per chunk; the top rule rides
    // the first chunk and the bottom rule the last.
    auto chunks = drawTableChunks!false([["a", "b"], ["c", "d"]]).array;
    assert(chunks.length == 4);
    const ia = chunks.countUntil!(c => c.canFind("a"));
    const ib = chunks.countUntil!(c => c.canFind("b"));
    const ic = chunks.countUntil!(c => c.canFind("c"));
    const id = chunks.countUntil!(c => c.canFind("d"));
    assert(ia == 0 && ib == 1 && ic == 2 && id == 3);
    assert(chunks[0].canFind("╭"));  // leading frame merged in
    assert(chunks[3].canFind("╰"));  // trailing frame merged in
}

@("drawTable.chunks.blankTablesAreOneFrameChunk")
@system unittest
{
    import std.algorithm.iteration : joiner;
    import std.array : array;
    import std.conv : to;

    // No contentful field at all -> a single chunk carrying the whole frame.
    auto chunks = drawTableChunks!false([[""]]).array;
    assert(chunks.length == 1);
    assert(chunks[0] == drawTable([[""]]));

    // A blank last row still flushes the bottom border onto the final content
    // chunk.
    auto tail = drawTableChunks!false([["x"], [""]]).array;
    assert(tail.length == 1);
    assert(tail.joiner.to!string == drawTable([["x"], [""]]));
}

@("drawTable.align.perCellOverride")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // The canonical use: a centered colspan header over left columns; a
    // per-cell right override beats the column default.
    checkRender(drawTable([
        [Cell("Totals", colSpan: 2, halign: Align.center)],
        [Cell("alpha"), Cell("1")],
        [Cell("beta"), Cell("2", halign: Align.right)],
    ]), `
        ╭───────────╮
        │  Totals   │
        │ alpha │ 1 │
        │ beta  │ 2 │
        ╰───────┴───╯
        `.outdent(2));

    // Sparse form carries the same overrides.
    const sparse = drawTable([
        Placement(0, 0, "Totals", colSpan: 2, halign: Align.center),
        Placement(1, 0, "alpha"), Placement(1, 1, "1"),
    ]);
    const dense = drawTable([
        [Cell("Totals", colSpan: 2, halign: Align.center)],
        [Cell("alpha"), Cell("1")],
    ]);
    assert(sparse == dense);
}

@("drawTableMapped.hit.basic")
@system unittest
{
    import std.string : indexOf;

    auto mt = drawTableMapped([["Name", "Status"], ["web-01", "Running"]],
        TableProps(headerRows: 1));
    assert(mt.map.numRows == 2 && mt.map.numCols == 2);

    // Locate the two body lines and each cell's display column (box glyphs are
    // multibyte, so map the byte index through visibleWidth).
    size_t nameLine, dataLine;
    foreach (i, ln; mt.lines)
    {
        if (ln.indexOf("Name") >= 0) nameLine = i;
        if (ln.indexOf("web-01") >= 0) dataLine = i;
    }
    size_t dcol(size_t line, string needle)
    {
        const b = mt.lines[line].indexOf(needle);
        return visibleWidth(mt.lines[line][0 .. b]);
    }

    const nx = dcol(nameLine, "Name");
    auto h = mt.map.hit(nameLine, nx);
    assert(!h.isNull && h.get.row == 0 && h.get.col == 0 && h.get.charInCell == 0);
    assert(mt.map.hit(nameLine, nx + 2).get.charInCell == 2); // the 'm' of Name
    assert(mt.map.cellText(0, 0) == "Name");

    auto h2 = mt.map.hit(dataLine, dcol(dataLine, "Running"));
    assert(!h2.isNull && h2.get.row == 1 && h2.get.col == 1 && h2.get.charInCell == 0);
    assert(mt.map.cellText(1, 1) == "Running");

    // Borders / other lines are not cells.
    assert(mt.map.hit(nameLine, 0).isNull);   // left border │
    assert(mt.map.hit(0, nx).isNull);         // the top rule

    auto sp = mt.map.cellSpans(0, 0);
    assert(sp.length == 1 && sp[0].line == nameLine && sp[0].xStart <= nx);
    auto cs = mt.map.charSpans(0, 0, 0, 2); // "Na"
    assert(cs.length == 1 && cs[0].line == nameLine && cs[0].xStart == nx);
}

@("drawTableMapped.hit.rightAlign")
@system unittest
{
    import std.string : indexOf;

    // col0 right-aligned, width 6 (max "header", "ab"): row 1 renders "    ab".
    auto mt = drawTableMapped([["header"], ["ab"]], TableProps(columnAligns: [Align.right]));
    size_t abLine;
    foreach (i, ln; mt.lines)
        if (ln.indexOf("ab") >= 0) abLine = i;
    const bIdx = mt.lines[abLine].indexOf("ab");
    const ax = visibleWidth(mt.lines[abLine][0 .. bIdx]); // display col of 'a'

    // A click one column into the leading pad snaps to char 0 of the cell.
    auto hpad = mt.map.hit(abLine, ax - 1);
    assert(!hpad.isNull && hpad.get.row == 1 && hpad.get.col == 0 && hpad.get.charInCell == 0);
    assert(mt.map.hit(abLine, ax + 1).get.charInCell == 1); // the 'b'
    assert(mt.map.cellText(1, 0) == "ab");
}

@("drawTableMapped.hit.wrappedCell")
@system unittest
{
    // A width cap forces the single cell to wrap across body lines; the map must
    // still resolve all of them to cell (0,0) with advancing char offsets.
    auto mt = drawTableMapped([["aaa bbb ccc"]], TableProps(maxWidth: 7));
    auto sp = mt.map.cellSpans(0, 0);
    assert(sp.length >= 2); // wrapped
    auto h0 = mt.map.hit(sp[0].line, sp[0].xStart);
    auto h1 = mt.map.hit(sp[1].line, sp[1].xStart);
    assert(!h1.isNull && h1.get.row == 0 && h1.get.col == 0);
    assert(h1.get.charInCell > h0.get.charInCell); // second wrapped line is later
    assert(mt.map.cellText(0, 0) == "aaa bbb ccc");
}
