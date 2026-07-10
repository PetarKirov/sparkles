module sparkles.core_cli.ui.table.render;

import std.array : array, appender;
import std.algorithm : map, all, maxElement, sort;
import std.algorithm.comparison : max, min;
import std.range : iota;
import std.range.primitives : isOutputRange;

import expected : Expected, ok, err;

import sparkles.base.text.grapheme : visibleWidth;
import sparkles.base.text.width : Align, alignField;

import sparkles.core_cli.ui.table.grid;


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

/// Interior junction glyphs for one emphasized rule (a heavy header row, a heavy
/// stub column, or their heavy crossing). Only the emphasized axis's arms are
/// heavy; the mask→glyph mapping matches `junctionGlyph`. Selected via
/// `TableProps.headerRows` / `headerCols`.
struct EmphasisGlyphs
{
    dchar horizontalLine, verticalLine;
    dchar teeDown, teeUp, teeRight, teeLeft, cross;
    dchar cornerTL, cornerTR, cornerBL, cornerBR;
}

/// The configurable box-drawing glyph set. Defaults are the rounded frame plus the
/// square interior corners spans create; every field is a caller-overridable `dchar`.
struct TableGlyphs
{
    dchar topLeft = '╭', topRight = '╮', bottomLeft = '╰', bottomRight = '╯';
    dchar horizontalLine = '─', verticalLine = '│';
    dchar teeDown = '┬', teeUp = '┴', teeRight = '├', teeLeft = '┤', cross = '┼';
    dchar cornerTL = '┌', cornerTR = '┐', cornerBL = '└', cornerBR = '┘';
    /// Decorations around a `TableProps.title`/`footer` spliced into the border
    /// (`╭──╼ Title ╾─┬──╮`), matching `drawBox`'s frame decorations.
    dchar titlePrefix = '╼', titleSuffix = '╾';

    /// Header-ROW rule: heavy horizontal, light vertical (`┝━━┿━━┥`).
    EmphasisGlyphs headerRow = EmphasisGlyphs(
        horizontalLine: '━', verticalLine: '│',
        teeDown: '┯', teeUp: '┷', teeRight: '┝', teeLeft: '┥', cross: '┿',
        cornerTL: '┍', cornerTR: '┑', cornerBL: '┕', cornerBR: '┙');
    /// Header/stub COLUMN rule: heavy vertical, light horizontal (`┰ ┃ ╂ ┸`).
    EmphasisGlyphs headerCol = EmphasisGlyphs(
        horizontalLine: '─', verticalLine: '┃',
        teeDown: '┰', teeUp: '┸', teeRight: '┠', teeLeft: '┨', cross: '╂',
        cornerTL: '┎', cornerTR: '┒', cornerBL: '┖', cornerBR: '┚');
    /// Where a header row and stub column rule cross: heavy both (`╋`).
    EmphasisGlyphs headerBoth = EmphasisGlyphs(
        horizontalLine: '━', verticalLine: '┃',
        teeDown: '┳', teeUp: '┻', teeRight: '┣', teeLeft: '┫', cross: '╋',
        cornerTL: '┏', cornerTR: '┓', cornerBL: '┗', cornerBR: '┛');
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

    /// Number of leading header rows: a distinct rule (the `glyphs.headerRow` set,
    /// heavy by default) is drawn after this many rows. `0` (default) draws no
    /// header rule. Independent of `rowSeparators`; when both apply to the same
    /// boundary the header glyphs win, so the header rule still stands out.
    size_t headerRows = 0;
    /// Number of leading stub / row-header columns: a distinct vertical rule (the
    /// `glyphs.headerCol` set, heavy by default) is drawn after this many columns.
    /// `0` (default) draws no stub rule. Independent of `columnSeparators` — the
    /// stub rule is drawn and width-budgeted even when column separators are off.
    size_t headerCols = 0;

    /// Total table width cap in columns, **including** separators and borders, or 0
    /// for no cap (expand to fit — today's behaviour). When set, columns are shrunk
    /// largest-first and their content wraps so no rendered line exceeds it. Feed it
    /// the terminal width (e.g. via `sparkles.core_cli.term_caps`) to fit output.
    size_t maxWidth = 0;

    /// Per-column max **content** width (excluding separators/gutters); a `0` entry or
    /// a short/empty array means that column is unbounded. Content over a column's cap
    /// wraps.
    size_t[] columnMaxWidths = null;

    /// Optional title/footer, spliced into the top/bottom border like `drawBox`'s
    /// (`╭──╼ Title ╾─┬──╮`), truncated with `…` when the table is too narrow. May
    /// carry ANSI styling (measured by visible width). With `border: false` they
    /// render as plain lines above/below the rows.
    string title = null;
    string footer = null; /// ditto

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

/// The names of the built-in glyph presets, in a stable order (`rounded` first).
immutable string[] builtinPresetNames = [
    "rounded", "square", "ascii", "double", "heavy"
];

/// The built-in glyph preset for `name` (one of `builtinPresetNames`); an unknown
/// name falls back to the `rounded` default. Pure and self-contained, so it works
/// **without** the module constructor that seeds `stylePresets` — e.g. in a wasm
/// build where `static this()` module ctors do not run.
TableGlyphs presetGlyphs(string name) @safe pure nothrow
{
    switch (name)
    {
        // square keeps the built-in heavy-mix emphasis defaults (its light frame
        // reads the heavy header/stub rules correctly).
        case "square":
            return TableGlyphs(
                topLeft: '┌', topRight: '┐', bottomLeft: '└', bottomRight: '┘',
                horizontalLine: '─', verticalLine: '│',
                teeDown: '┬', teeUp: '┴', teeRight: '├', teeLeft: '┤', cross: '┼',
                cornerTL: '┌', cornerTR: '┐', cornerBL: '└', cornerBR: '┘');
        // ascii: the '===' header-row convention is the only distinct emphasis
        // available; the stub column reuses the body '|'/'+' (no heavier ascii glyph).
        case "ascii":
            enum EmphasisGlyphs asciiEmph = EmphasisGlyphs(
                horizontalLine: '-', verticalLine: '|',
                teeDown: '+', teeUp: '+', teeRight: '+', teeLeft: '+', cross: '+',
                cornerTL: '+', cornerTR: '+', cornerBL: '+', cornerBR: '+');
            enum EmphasisGlyphs asciiHeaderRow = EmphasisGlyphs(
                horizontalLine: '=', verticalLine: '|',
                teeDown: '+', teeUp: '+', teeRight: '+', teeLeft: '+', cross: '+',
                cornerTL: '+', cornerTR: '+', cornerBL: '+', cornerBR: '+');
            return TableGlyphs(
                topLeft: '+', topRight: '+', bottomLeft: '+', bottomRight: '+',
                horizontalLine: '-', verticalLine: '|',
                teeDown: '+', teeUp: '+', teeRight: '+', teeLeft: '+', cross: '+',
                cornerTL: '+', cornerTR: '+', cornerBL: '+', cornerBR: '+',
                titlePrefix: '[', titleSuffix: ']',
                headerRow: asciiHeaderRow, headerCol: asciiEmph, headerBoth: asciiHeaderRow);
        // double & heavy have no heavier form, so their emphasis rules reuse the body
        // glyphs (drawn, but not visually heavier).
        case "double":
            enum EmphasisGlyphs doubleEmph = EmphasisGlyphs(
                horizontalLine: '═', verticalLine: '║',
                teeDown: '╦', teeUp: '╩', teeRight: '╠', teeLeft: '╣', cross: '╬',
                cornerTL: '╔', cornerTR: '╗', cornerBL: '╚', cornerBR: '╝');
            return TableGlyphs(
                topLeft: '╔', topRight: '╗', bottomLeft: '╚', bottomRight: '╝',
                horizontalLine: '═', verticalLine: '║',
                teeDown: '╦', teeUp: '╩', teeRight: '╠', teeLeft: '╣', cross: '╬',
                cornerTL: '╔', cornerTR: '╗', cornerBL: '╚', cornerBR: '╝',
                titlePrefix: '╡', titleSuffix: '╞',
                headerRow: doubleEmph, headerCol: doubleEmph, headerBoth: doubleEmph);
        case "heavy":
            enum EmphasisGlyphs heavyEmph = EmphasisGlyphs(
                horizontalLine: '━', verticalLine: '┃',
                teeDown: '┳', teeUp: '┻', teeRight: '┣', teeLeft: '┫', cross: '╋',
                cornerTL: '┏', cornerTR: '┓', cornerBL: '┗', cornerBR: '┛');
            return TableGlyphs(
                topLeft: '┏', topRight: '┓', bottomLeft: '┗', bottomRight: '┛',
                horizontalLine: '━', verticalLine: '┃',
                teeDown: '┳', teeUp: '┻', teeRight: '┣', teeLeft: '┫', cross: '╋',
                cornerTL: '┏', cornerTR: '┓', cornerBL: '┗', cornerBR: '┛',
                titlePrefix: '┫', titleSuffix: '┣',
                headerRow: heavyEmph, headerCol: heavyEmph, headerBoth: heavyEmph);
        case "rounded":
        default:
            return TableGlyphs.init;
    }
}

/// Named glyph presets, selectable as `TableProps(glyphs: stylePresets["ascii"])`.
/// Seeded from `presetGlyphs` with `rounded` (the default, `== TableGlyphs.init`),
/// `square`, `ascii`, `double`, and `heavy`; callers may register or override their
/// own entries. Thread local (each thread gets the built-ins), so reads stay `@safe`.
/// Prefer `presetGlyphs(name)` where a pure lookup that needs no module ctor helps
/// (e.g. a wasm build).
TableGlyphs[string] stylePresets;

static this()
{
    foreach (name; builtinPresetNames)
        stylePresets[name] = presetGlyphs(name);
}

/// Is interior lattice row `i` the header-row rule (drawn after `headerRows` rows)?
/// Guarded to an interior boundary so `headerRows >= numRows` is a silent no-op.
private bool isHeaderRow(in TableProps p, size_t i, size_t numRows) @safe pure nothrow @nogc
    => p.headerRows > 0 && i == p.headerRows && i < numRows;

/// Is interior boundary `j` the stub-column rule (drawn after `headerCols` columns)?
private bool isHeaderCol(in TableProps p, size_t j, size_t numCols) @safe pure nothrow @nogc
    => p.headerCols > 0 && j == p.headerCols && j < numCols;

/// Width (0 or 1) of interior boundary `j` (`1 .. numCols-1`): a lattice column
/// exists where column separators are on, or where the stub rule sits. With
/// `headerCols == 0` this collapses to `columnSeparators ? 1 : 0`.
private size_t sepWidth(in TableProps p, size_t j, size_t numCols) @safe pure nothrow @nogc
    => (p.columnSeparators || isHeaderCol(p, j, numCols)) ? 1 : 0;

/// The visible-column field a cell occupies: its member column widths plus, per
/// merged boundary, the two gutters and the separator column it absorbs (`sepWidth`
/// per internal boundary — 1 with column separators on or at the stub rule, else 0).
private size_t contentField(in Anchor a, in size_t[] w, in TableProps p, size_t numCols) @safe pure nothrow @nogc
{
    size_t f = 2 * (a.colSpan - 1);
    foreach (k; 1 .. a.colSpan)
        f += sepWidth(p, a.col + k, numCols);
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

/// Per-anchor trailing pads implementing `Align.decimal`: within each decimal
/// column, every value's last `.` lands on the same cell — dotted values pad by
/// `maxTail - tail`, dotless ones by `maxTail + 1` (their last digit sits just
/// left of the dot column). Header rows (`< headerRows`) and span cells are
/// exempt (they right-align plainly). Null when no column is decimal; a decimal
/// column with no dotted value degrades to plain right (all pads stay 0).
private size_t[] anchorDecimalPads(in SlotGrid g, in TableProps p) @safe pure
{
    bool any = false;
    foreach (c; 0 .. g.numCols)
        any = any || effectiveAlign(c, p) == Align.decimal;
    if (!any)
        return null;

    bool decimalBody(in Anchor a)
        => a.colSpan == 1 && a.row >= p.headerRows
            && effectiveAlign(a.col, p) == Align.decimal;

    auto maxTail = new size_t[g.numCols];
    auto dotted = new bool[g.numCols];
    foreach (ref a; g.anchors)
        if (decimalBody(a))
        {
            const t = decimalTailWidth(a.content);
            if (t != size_t.max)
            {
                dotted[a.col] = true;
                maxTail[a.col] = max(maxTail[a.col], t);
            }
        }

    auto pads = new size_t[g.anchors.length];
    foreach (i, ref a; g.anchors)
        if (decimalBody(a) && dotted[a.col])
        {
            const t = decimalTailWidth(a.content);
            pads[i] = t == size_t.max ? maxTail[a.col] + 1 : maxTail[a.col] - t;
        }
    return pads;
}

private size_t[] resolveColumnWidths(
    in SlotGrid g, in TableProps p, in size_t[] decimalPads = null) @safe pure
{
    auto w = new size_t[g.numCols];
    foreach (i, ref a; g.anchors)
        if (a.colSpan == 1)
            w[a.col] = max(w[a.col],
                naturalWidth(a.content) + (decimalPads.length ? decimalPads[i] : 0));

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
        // gutters + the separator columns (per internal boundary) the span covers
        size_t absorbed = 2 * (n - 1);
        foreach (k; 1 .. n)
            absorbed += sepWidth(p, a.col + k, g.numCols);
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
        size_t interiorSep = 0;
        foreach (j; 1 .. g.numCols)
            interiorSep += sepWidth(p, j, g.numCols);
        const frame = 2 * g.numCols + interiorSep + 2 * borderW;
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
/// follow `border`; interior verticals follow `columnSeparators` (or the stub rule
/// at `headerCols`) and vanish where a colspan crosses (the same anchor owns both
/// sides).
private bool vSeg(in SlotGrid g, in TableProps p, size_t r, size_t j) @safe pure nothrow @nogc
{
    if (j == 0 || j == g.numCols)
        return p.border;
    if (!p.columnSeparators && !isHeaderCol(p, j, g.numCols))
        return false;
    return owner(g, r, j - 1) != owner(g, r, j);
}

/// Is a horizontal grid segment drawn on rule `i` within column `c`? Frame edges
/// follow `border`; interior rules follow `rowSeparators` (or the header rule at
/// `headerRows`) and vanish where a rowspan crosses.
private bool hSeg(in SlotGrid g, in TableProps p, size_t i, size_t c) @safe pure nothrow @nogc
{
    if (i == 0 || i == g.numRows)
        return p.border;
    if (!p.rowSeparators && !isHeaderRow(p, i, g.numRows))
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

    // Pick the interior glyph set: heavy along whichever emphasized rule(s) this
    // junction sits on (header row, stub column, or both), else the normal light
    // set assembled from the flat fields.
    const hdrRow = isHeaderRow(p, i, g.numRows);
    const hdrCol = isHeaderCol(p, j, g.numCols);
    const EmphasisGlyphs set =
        (hdrRow && hdrCol) ? p.glyphs.headerBoth
        : hdrRow ? p.glyphs.headerRow
        : hdrCol ? p.glyphs.headerCol
        : EmphasisGlyphs(
            horizontalLine: p.glyphs.horizontalLine, verticalLine: p.glyphs.verticalLine,
            teeDown: p.glyphs.teeDown, teeUp: p.glyphs.teeUp, teeRight: p.glyphs.teeRight,
            teeLeft: p.glyphs.teeLeft, cross: p.glyphs.cross,
            cornerTL: p.glyphs.cornerTL, cornerTR: p.glyphs.cornerTR,
            cornerBL: p.glyphs.cornerBL, cornerBR: p.glyphs.cornerBR);

    const m = (u << 3) | (d << 2) | (l << 1) | r;
    final switch (m)
    {
        case 0b0000: return ' ';
        case 0b0001: case 0b0010: case 0b0011: return set.horizontalLine;
        case 0b0100: case 0b1000: case 0b1100: return set.verticalLine;
        case 0b0101: return set.cornerTL; // down + right
        case 0b0110: return set.cornerTR; // down + left
        case 0b1001: return set.cornerBL; // up + right
        case 0b1010: return set.cornerBR; // up + left
        case 0b0111: return set.teeDown;
        case 0b1011: return set.teeUp;
        case 0b1101: return set.teeRight;
        case 0b1110: return set.teeLeft;
        case 0b1111: return set.cross;
    }
}

/// One horizontal rule (top border, interior row separator, or bottom border) at
/// lattice row `i`: junctions interleaved with per-column fills.
private string separatorLine(in SlotGrid g, in size_t[] w, in TableProps p, size_t i)
{
    // A lattice column is 1 char wide only when its line is drawn: the outer two
    // follow `border`, the interior ones `sepWidth` (column separators or a stub
    // rule). A zero-width lattice is skipped in both bands and rules, so the two
    // always share the same width.
    const hdrRow = isHeaderRow(p, i, g.numRows);
    const fillGlyph = hdrRow ? p.glyphs.headerRow.horizontalLine : p.glyphs.horizontalLine;
    auto line = appender!string;
    foreach (j; 0 .. g.numCols)
    {
        const latticeDrawn = j == 0 ? p.border : sepWidth(p, j, g.numCols) > 0;
        if (latticeDrawn)
            line ~= junctionGlyph(g, p, i, j);
        const fillCh = hSeg(g, p, i, j) ? fillGlyph : ' ';
        foreach (_; 0 .. w[j] + 2)
            line ~= fillCh;
    }
    if (p.border)
        line ~= junctionGlyph(g, p, i, g.numCols);
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

/// Render text line `t` of grid row `r` (`t < layout.rowHeights[r]`). Each anchor
/// emits its wrapped line for the current text line in its content band, or a blank
/// field otherwise, separated by interior verticals where a real boundary sits.
/// No trailing newline — emission joins lines (see `lineDescs`/`renderLine`).
private string bodyLine(in TableLayout lay, size_t r, size_t t)
{
    const g = lay.grid;
    const p = lay.props;
    auto out_ = appender!string;
    if (p.border)
        out_ ~= p.glyphs.verticalLine;
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
        const top = padTop(hh, lay.cellLines[idx].length, effectiveVAlign(a.col, p));
        out_ ~= ' ';
        if (li >= top && li - top < lay.cellLines[idx].length)
        {
            // A decimal column's trailing pad shifts the right-aligned value
            // left so every dot in the column shares a cell.
            const dpad = lay.decimalPads.length ? lay.decimalPads[idx] : 0;
            if (dpad > 0 && dpad < f)
            {
                alignField(out_, lay.cellLines[idx][li - top], f - dpad, Align.right);
                foreach (_; 0 .. dpad)
                    out_ ~= ' ';
            }
            else
                alignField(out_, lay.cellLines[idx][li - top], f, effectiveAlign(a.col, p));
        }
        else
            foreach (_; 0 .. f)
                out_ ~= ' ';
        out_ ~= ' ';
        c += a.colSpan;
        if (c < g.numCols && vSeg(lay.grid, p, r, c))
            out_ ~= isHeaderCol(p, c, g.numCols)
                ? p.glyphs.headerCol.verticalLine : p.glyphs.verticalLine;
    }
    if (p.border)
        out_ ~= p.glyphs.verticalLine;
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
package(sparkles.core_cli.ui.table) struct TableLayout
{
    SlotGrid grid;
    TableProps props;
    size_t[] decimalPads;   /// per-anchor `Align.decimal` trailing pads
    size_t[] widths;        /// per-column content widths
    string[][] cellLines;   /// per-anchor wrapped content lines
    size_t[] rowHeights;    /// per grid-row text height
}

/// Resolve `g` under `p` into a $(LREF TableLayout).
package(sparkles.core_cli.ui.table) TableLayout computeTableLayout(
    SlotGrid g, TableProps p)
{
    auto decimalPads = anchorDecimalPads(g, p);
    auto widths = resolveColumnWidths(g, p, decimalPads);
    auto cellLines = wrapCells(g, widths, p);
    auto rowHeights = resolveRowHeights(g, cellLines);
    return TableLayout(g, p, decimalPads, widths, cellLines, rowHeights);
}

/// What one output line of a rendered table is (see $(LREF lineDescs)).
private enum LineKind : ubyte
{
    topRule,     /// top border, carrying the title when set
    titlePlain,  /// `border: false` title as a plain line
    body,        /// text line `t` of grid row `r`
    rule,        /// interior separator above grid row `r`
    bottomRule,  /// bottom border, carrying the footer when set
    footerPlain, /// `border: false` footer as a plain line
}

/// ditto
private struct LineDesc
{
    LineKind kind;
    size_t r, t;
}

/// The table's output lines as descriptors, in order — the single source of
/// truth both the eager renderer and the lazy line/chunk views walk, so the
/// two cannot drift. Empty grid → empty (drawTable's historical `""`).
private LineDesc[] lineDescs(in TableLayout lay) @safe pure
{
    const g = lay.grid;
    const p = lay.props;
    if (g.numRows == 0 || g.numCols == 0)
        return null;

    LineDesc[] descs;
    if (p.border)
        descs ~= LineDesc(LineKind.topRule);
    else if (p.title.length)
        descs ~= LineDesc(LineKind.titlePlain);
    foreach (r; 0 .. g.numRows)
    {
        foreach (t; 0 .. lay.rowHeights[r])
            descs ~= LineDesc(LineKind.body, r, t);
        if (r + 1 < g.numRows
                && (p.rowSeparators || (p.headerRows > 0 && r + 1 == p.headerRows)))
            descs ~= LineDesc(LineKind.rule, r + 1);
    }
    if (p.border)
        descs ~= LineDesc(LineKind.bottomRule);
    else if (p.footer.length)
        descs ~= LineDesc(LineKind.footerPlain);
    return descs;
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
    foreach (d; lineDescs(lay))
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
    return TableLineRange(lay, lineDescs(lay));
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
    import std.array : appender;

    static void checkWriterParity(T)(T cells, TableProps props)
    {
        auto w = appender!string;
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
    auto w = appender!string;
    drawTable(w, [["x"]]).put("tail");
    assert(w[] == drawTable([["x"]]) ~ "tail");
}
