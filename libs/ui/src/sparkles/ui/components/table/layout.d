/++
The content-agnostic table layout core shared by the component's views: the
rendering configuration (`TableProps`, `TableGlyphs`, the glyph presets), the
alignment/emphasis resolution helpers, the column-width / row-height solvers,
the junction-glyph logic, and the output-line ordering (`lineDescs`).

Nothing in this module measures cell $(I content) — the solvers take
precomputed per-anchor natural widths, wrapped-line counts, and decimal tail
widths, so each view brings its own measure and wrap engine: the string view
(`sparkles.ui.components.table.render`) measures with the grapheme-aware
`visibleWidth` and wraps with `sparkles.base.text.wrap`, while the widget view
measures with the toolkit's `cellsOf` and wraps with `sparkles.ui.wrap` (the
display list and selection geometry hard-wire `cellsOf`, so the two views
$(I deliberately) diverge on CJK/emoji widths). Both are re-exported through
the `sparkles.ui.components.table` package module.
+/
module sparkles.ui.components.table.layout;

import std.algorithm : sort;
import std.algorithm.comparison : max, min;

import sparkles.base.text.width : Align;

import sparkles.ui.components.table.grid;

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
    /// the terminal width (e.g. via `sparkles.base.term_caps`) to fit output.
    size_t maxWidth = 0;

    /// Per-column max **content** width (excluding separators/gutters); a `0` entry or
    /// a short/empty array means that column is unbounded. Content over a column's cap
    /// wraps.
    size_t[] columnMaxWidths = null;

    /// Per-column min **content** width (excluding separators/gutters); a `0` entry or
    /// a short/empty array leaves that column at its natural width. A layout floor —
    /// use it to keep a live/streaming table's geometry stable across re-renders while
    /// content is still arriving. The caps win on conflict: a `columnMaxWidths` entry
    /// below the floor still caps the column, and the total `maxWidth` shrink still
    /// applies.
    size_t[] columnMinWidths = null;

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
package(sparkles.ui.components.table)
Align effectiveAlign(size_t c, in TableProps p) @safe pure nothrow @nogc
{
    if (c < p.columnAligns.length && p.columnAligns[c] != Align.inherit)
        return p.columnAligns[c];
    return p.defaultAlign == Align.inherit ? Align.left : p.defaultAlign;
}

/// The effective vertical alignment for column `c` (`inherit` resolves to `top`).
package(sparkles.ui.components.table)
VAlign effectiveVAlign(size_t c, in TableProps p) @safe pure nothrow @nogc
{
    if (c < p.columnVAligns.length && p.columnVAligns[c] != VAlign.inherit)
        return p.columnVAligns[c];
    return p.defaultVAlign == VAlign.inherit ? VAlign.top : p.defaultVAlign;
}

/// The effective alignment for an anchor: its own per-cell override when set,
/// else the column/table default.
package(sparkles.ui.components.table)
Align anchorAlign(in Anchor a, in TableProps p) @safe pure nothrow @nogc
    => a.halign != Align.inherit ? a.halign : effectiveAlign(a.col, p);

/// ditto
package(sparkles.ui.components.table)
VAlign anchorVAlign(in Anchor a, in TableProps p) @safe pure nothrow @nogc
    => a.valign != VAlign.inherit ? a.valign : effectiveVAlign(a.col, p);

/// Blank lines above a content block of `l` lines placed in a field of `hh` lines.
package(sparkles.ui.components.table)
size_t padTop(size_t hh, size_t l, VAlign va) @safe pure nothrow @nogc
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
package(sparkles.ui.components.table)
bool isHeaderRow(in TableProps p, size_t i, size_t numRows) @safe pure nothrow @nogc
    => p.headerRows > 0 && i == p.headerRows && i < numRows;

/// Is interior boundary `j` the stub-column rule (drawn after `headerCols` columns)?
package(sparkles.ui.components.table)
bool isHeaderCol(in TableProps p, size_t j, size_t numCols) @safe pure nothrow @nogc
    => p.headerCols > 0 && j == p.headerCols && j < numCols;

/// Width (0 or 1) of interior boundary `j` (`1 .. numCols-1`): a lattice column
/// exists where column separators are on, or where the stub rule sits. With
/// `headerCols == 0` this collapses to `columnSeparators ? 1 : 0`.
package(sparkles.ui.components.table)
size_t sepWidth(in TableProps p, size_t j, size_t numCols) @safe pure nothrow @nogc
    => (p.columnSeparators || isHeaderCol(p, j, numCols)) ? 1 : 0;

/// The visible-column field a cell occupies: its member column widths plus, per
/// merged boundary, the two gutters and the separator column it absorbs (`sepWidth`
/// per internal boundary — 1 with column separators on or at the stub rule, else 0).
package(sparkles.ui.components.table)
size_t contentField(in Anchor a, in size_t[] w, in TableProps p, size_t numCols) @safe pure nothrow @nogc
{
    size_t f = 2 * (a.colSpan - 1);
    foreach (k; 1 .. a.colSpan)
        f += sepWidth(p, a.col + k, numCols);
    foreach (c; a.col .. a.col + a.colSpan)
        f += w[c];
    return f;
}

/// Per-anchor trailing pads implementing `Align.decimal` from per-anchor decimal
/// tail widths (`tailWidths[i]` — the visible width after the last `.` of anchor
/// `i`'s content, or `size_t.max` when it has no dot; how a tail is measured is
/// the view's business). Within each decimal column, every value's last `.`
/// lands on the same cell — dotted values pad by `maxTail - tail`, dotless ones
/// by `maxTail + 1` (their last digit sits just left of the dot column). Header
/// rows (`< headerRows`) and span cells are exempt (they right-align plainly).
/// Null when no column is decimal; a decimal column with no dotted value
/// degrades to plain right (all pads stay 0).
package(sparkles.ui.components.table)
size_t[] decimalPadsFor(in SlotGrid g, in TableProps p, in size_t[] tailWidths) @safe pure
{
    bool any = false;
    foreach (c; 0 .. g.numCols)
        any = any || effectiveAlign(c, p) == Align.decimal;
    if (!any)
        return null;

    bool decimalBody(in Anchor a)
        => a.colSpan == 1 && a.row >= p.headerRows
            && anchorAlign(a, p) == Align.decimal;

    auto maxTail = new size_t[g.numCols];
    auto dotted = new bool[g.numCols];
    foreach (i, ref a; g.anchors)
        if (decimalBody(a))
        {
            const t = tailWidths[i];
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
            const t = tailWidths[i];
            pads[i] = t == size_t.max ? maxTail[a.col] + 1 : maxTail[a.col] - t;
        }
    return pads;
}

/// Per-column content widths from per-anchor natural widths (`naturalWidths[i]`
/// — the widest line of anchor `i`'s content, in whatever measure the view
/// uses): per-column max of extent-1 anchors, floors, colspan distribution,
/// caps, then the total `maxWidth` shrink.
package(sparkles.ui.components.table)
size_t[] resolveColumnWidths(in SlotGrid g, in TableProps p,
    in size_t[] naturalWidths, in size_t[] decimalPads = null) @safe pure
{
    auto w = new size_t[g.numCols];
    foreach (i, ref a; g.anchors)
        if (a.colSpan == 1)
            w[a.col] = max(w[a.col],
                naturalWidths[i] + (decimalPads.length ? decimalPads[i] : 0));

    // Per-column floors, applied before the colspan distribution (columns only
    // grow, so a floored column may already satisfy a spanning cell) and before
    // the caps — columnMaxWidths and maxWidth still win, keeping fit guarantees.
    foreach (c; 0 .. g.numCols)
        if (c < p.columnMinWidths.length)
            w[c] = max(w[c], p.columnMinWidths[c]);

    // Satisfy colspan cells ascending by span then position: columns only grow, so
    // one pass leaves every spanning cell fitting its final member-column widths.
    size_t[] spanning;
    foreach (i, ref a; g.anchors)
        if (a.colSpan >= 2)
            spanning ~= i;
    spanning.sort!((x, y) => g.anchors[x].colSpan != g.anchors[y].colSpan
            ? g.anchors[x].colSpan < g.anchors[y].colSpan
            : (g.anchors[x].row != g.anchors[y].row
                ? g.anchors[x].row < g.anchors[y].row
                : g.anchors[x].col < g.anchors[y].col));
    foreach (i; spanning)
    {
        const a = g.anchors[i];
        const n = a.colSpan;
        const vw = naturalWidths[i];
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

/// Per grid-row text height (≥ 1) from per-anchor wrapped-line counts
/// (`cellLineCounts[i]` — how many lines anchor `i`'s content wrapped to): the
/// max among extent-1 cells, then grown so every rowspan cell's lines fit
/// across its bands' combined height (ascending by span; rows only grow, so
/// one pass satisfies all — like the colspan width distribution).
package(sparkles.ui.components.table)
size_t[] resolveRowHeights(in SlotGrid g, in size_t[] cellLineCounts) @safe pure nothrow
{
    auto h = new size_t[g.numRows];
    foreach (ref x; h)
        x = 1;
    foreach (i, ref a; g.anchors)
        if (a.rowSpan == 1)
            h[a.row] = max(h[a.row], cellLineCounts[i]);

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
        const need = cellLineCounts[i];
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

/// Is a vertical grid segment drawn on boundary `j` within band `r`? Frame edges
/// follow `border`; interior verticals follow `columnSeparators` (or the stub rule
/// at `headerCols`) and vanish where a colspan crosses (the same anchor owns both
/// sides).
package(sparkles.ui.components.table)
bool vSeg(in SlotGrid g, in TableProps p, size_t r, size_t j) @safe pure nothrow @nogc
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
package(sparkles.ui.components.table)
bool hSeg(in SlotGrid g, in TableProps p, size_t i, size_t c) @safe pure nothrow @nogc
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
package(sparkles.ui.components.table)
dchar junctionGlyph(in SlotGrid g, in TableProps p, size_t i, size_t j) @safe pure nothrow @nogc
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

/// What one output line of a rendered table is (see $(LREF lineDescs)).
package(sparkles.ui.components.table)
enum LineKind : ubyte
{
    topRule,     /// top border, carrying the title when set
    titlePlain,  /// `border: false` title as a plain line
    body,        /// text line `t` of grid row `r`
    rule,        /// interior separator above grid row `r`
    bottomRule,  /// bottom border, carrying the footer when set
    footerPlain, /// `border: false` footer as a plain line
}

/// ditto
package(sparkles.ui.components.table)
struct LineDesc
{
    LineKind kind;
    size_t r, t;
}

/// The table's output lines as descriptors, in order — the single source of
/// truth every view walks (the eager string renderer, the lazy line/chunk
/// views, the widget view), so they cannot drift. Empty grid → empty
/// (drawTable's historical `""`).
package(sparkles.ui.components.table)
LineDesc[] lineDescs(in SlotGrid g, in TableProps p, in size_t[] rowHeights) @safe pure
{
    if (g.numRows == 0 || g.numCols == 0)
        return null;

    LineDesc[] descs;
    if (p.border)
        descs ~= LineDesc(LineKind.topRule);
    else if (p.title.length)
        descs ~= LineDesc(LineKind.titlePlain);
    foreach (r; 0 .. g.numRows)
    {
        foreach (t; 0 .. rowHeights[r])
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

/// Leading pad an aligned field puts before its content (for column mapping).
package(sparkles.ui.components.table)
size_t leadPad(size_t width, size_t contentW, Align a) @safe pure nothrow @nogc
{
    if (contentW >= width)
        return 0;
    const pad = width - contentW;
    final switch (a)
    {
        case Align.inherit:
        case Align.left:    return 0;
        case Align.right:
        case Align.decimal: return pad;
        case Align.center:  return pad / 2;
    }
}

// ── shared placement geometry ────────────────────────────────────────────────
//
// One body-line walk serves every view: the string renderer's screen↔cell map
// derives from it, and the widget view positions its cell subtrees from it.
// Coordinates are output cells from the table's left edge (`x`) and output
// line indices in `lineDescs` order (`line`), so they line up with the emitted
// bytes / painted glyphs exactly.

/// The placement of one anchor's field on one body output line: the field
/// occupies `[x, x + width)`; when `hasContent` is set, wrapped content line
/// `lineInCell` of the anchor shows here (vertical alignment already applied),
/// else the field renders blank (an out-of-band rowspan line or an empty cell).
package(sparkles.ui.components.table)
struct FieldPlacement
{
    size_t line;       /// output line index (in `lineDescs` order)
    size_t anchor;     /// index into `SlotGrid.anchors`
    size_t x;          /// field start, cells from the table's left edge
    size_t width;      /// the `contentField` width
    size_t lineInCell; /// which wrapped content line shows here (when `hasContent`)
    bool hasContent;
}

/// One drawn vertical glyph cell on a body output line (the left/right border
/// or an interior separator), emphasis-resolved.
package(sparkles.ui.components.table)
struct RuleCell
{
    size_t line; /// output line index (in `lineDescs` order)
    size_t x;    /// cells from the table's left edge
    dchar glyph;
}

/// ditto
package(sparkles.ui.components.table)
struct BodyWalk
{
    FieldPlacement[] fields;
    RuleCell[] rules;
}

/// Walk every body output line, emitting each covering anchor's field
/// placement (blank fields included, `hasContent` distinguishing them) and
/// each drawn vertical rule cell, in line-major column order. `cellLineCounts`
/// is per-anchor (how many lines each anchor's content wrapped to) — the walk
/// applies vertical alignment (`padTop`) but never touches the content itself.
package(sparkles.ui.components.table)
BodyWalk walkBodyLines(in SlotGrid g, in TableProps p, in size_t[] widths,
    in size_t[] rowHeights, in size_t[] cellLineCounts) @safe pure
{
    BodyWalk walk;
    size_t outLine;
    foreach (d; lineDescs(g, p, rowHeights))
    {
        scope (exit) outLine++;
        if (d.kind != LineKind.body)
            continue;
        const r = d.r;
        size_t x = 0;
        if (p.border)
        {
            walk.rules ~= RuleCell(outLine, x, p.glyphs.verticalLine);
            x++;
        }
        size_t c = 0;
        while (c < g.numCols)
        {
            const idx = owner(g, r, c);
            const a = g.anchors[idx];
            const f = contentField(a, widths, p, g.numCols);
            x += 1; // leading gutter
            // This anchor's line index at row r, text line t: the sum of the
            // heights of its bands above r, plus t (a rowspan cell's content
            // flows down across its stacked bands); vertical alignment shifts
            // the content block down within the anchor's combined height.
            size_t li = d.t;
            foreach (rr; a.row .. r)
                li += rowHeights[rr];
            size_t hh = 0;
            foreach (rr; a.row .. a.row + a.rowSpan)
                hh += rowHeights[rr];
            const top = padTop(hh, cellLineCounts[idx], anchorVAlign(a, p));
            const has = li >= top && li - top < cellLineCounts[idx];
            walk.fields ~= FieldPlacement(outLine, idx, x, f,
                has ? li - top : 0, has);
            x += f + 1; // field + trailing gutter
            c += a.colSpan;
            if (c < g.numCols && vSeg(g, p, r, c))
            {
                walk.rules ~= RuleCell(outLine, x, isHeaderCol(p, c, g.numCols)
                    ? p.glyphs.headerCol.verticalLine : p.glyphs.verticalLine);
                x++;
            }
        }
        if (p.border)
            walk.rules ~= RuleCell(outLine, x, p.glyphs.verticalLine);
    }
    return walk;
}

/// The rendered table's total width in cells: every column with its two
/// gutters, the interior lattice columns, and the frame.
package(sparkles.ui.components.table)
size_t tableWidth(in TableProps p, in size_t[] widths, size_t numCols) @safe pure nothrow @nogc
{
    size_t w = p.border ? 2 : 0;
    foreach (c; 0 .. numCols)
        w += widths[c] + 2;
    foreach (j; 1 .. numCols)
        w += sepWidth(p, j, numCols);
    return w;
}

/// The rendered table's total output line count (`lineDescs`' length).
package(sparkles.ui.components.table)
size_t tableHeight(in SlotGrid g, in TableProps p, in size_t[] rowHeights) @safe pure
    => lineDescs(g, p, rowHeights).length;

/// The on-screen rectangle of one anchor, in output cells/lines: the field
/// plus both gutters wide (borders and separators excluded), and all of the
/// anchor's bands tall — a rowspan's rect swallows the interior rule lines
/// between its bands (they render blank inside the cell).
package(sparkles.ui.components.table)
struct AnchorRect
{
    size_t x, y, w, h;
}

/// ditto — indexed like `SlotGrid.anchors`.
package(sparkles.ui.components.table)
AnchorRect[] anchorRects(in SlotGrid g, in TableProps p, in size_t[] widths,
    in size_t[] rowHeights) @safe pure
{
    // Output-line span of each grid row's body lines.
    auto firstLine = new size_t[g.numRows];
    auto lastLine = new size_t[g.numRows];
    size_t outLine;
    foreach (d; lineDescs(g, p, rowHeights))
    {
        if (d.kind == LineKind.body)
        {
            if (d.t == 0)
                firstLine[d.r] = outLine;
            lastLine[d.r] = outLine;
        }
        outLine++;
    }

    // Field-start x of each grid column (span-independent: a spanning cell's
    // field starts where its anchor column's field starts).
    auto colX = new size_t[g.numCols];
    size_t x = p.border ? 1 : 0;
    foreach (c; 0 .. g.numCols)
    {
        x += 1; // leading gutter
        colX[c] = x;
        x += widths[c] + 1; // field + trailing gutter
        if (c + 1 < g.numCols)
            x += sepWidth(p, c + 1, g.numCols);
    }

    auto rects = new AnchorRect[g.anchors.length];
    foreach (i, ref a; g.anchors)
    {
        const f = contentField(a, widths, p, g.numCols);
        const y0 = firstLine[a.row];
        const y1 = lastLine[a.row + a.rowSpan - 1];
        rects[i] = AnchorRect(colX[a.col] - 1, y0, f + 2, y1 - y0 + 1);
    }
    return rects;
}

/// One horizontal rule (top border, interior row separator, or bottom border)
/// at lattice row `i`, as one glyph per output cell — the splice-able form of
/// the string view's `separatorLine` and the widget view's rule runs.
package(sparkles.ui.components.table)
dchar[] ruleGlyphs(in SlotGrid g, in TableProps p, in size_t[] widths, size_t i) @safe pure
{
    // A lattice column is 1 char wide only when its line is drawn: the outer two
    // follow `border`, the interior ones `sepWidth` (column separators or a stub
    // rule). A zero-width lattice is skipped in both bands and rules, so the two
    // always share the same width.
    const hdrRow = isHeaderRow(p, i, g.numRows);
    const fillGlyph = hdrRow ? p.glyphs.headerRow.horizontalLine : p.glyphs.horizontalLine;
    dchar[] line;
    foreach (j; 0 .. g.numCols)
    {
        const latticeDrawn = j == 0 ? p.border : sepWidth(p, j, g.numCols) > 0;
        if (latticeDrawn)
            line ~= junctionGlyph(g, p, i, j);
        const fillCh = hSeg(g, p, i, j) ? fillGlyph : ' ';
        foreach (_; 0 .. widths[j] + 2)
            line ~= fillCh;
    }
    if (p.border)
        line ~= junctionGlyph(g, p, i, g.numCols);
    return line;
}

/// A body line's frame at band `r` — borders, gutters and interior separators
/// with every field blank — as one glyph per output cell. Band-only (`t`-free):
/// the drawn verticals depend on the band, never on the text line within it.
package(sparkles.ui.components.table)
dchar[] frameLineGlyphs(in SlotGrid g, in TableProps p, in size_t[] widths, size_t r) @safe pure
{
    auto line = new dchar[](tableWidth(p, widths, g.numCols));
    line[] = ' ';
    if (p.border)
    {
        line[0] = p.glyphs.verticalLine;
        line[$ - 1] = p.glyphs.verticalLine;
    }
    size_t x = p.border ? 1 : 0;
    size_t c = 0;
    while (c < g.numCols)
    {
        const a = g.anchors[owner(g, r, c)];
        x += 1 + contentField(a, widths, p, g.numCols) + 1;
        c += a.colSpan;
        if (c < g.numCols && vSeg(g, p, r, c))
        {
            line[x] = isHeaderCol(p, c, g.numCols)
                ? p.glyphs.headerCol.verticalLine : p.glyphs.verticalLine;
            x++;
        }
    }
    return line;
}

version (unittest)
{
    private SlotGrid testGrid(in Cell[][] cells) @safe pure nothrow
        => resolveGrid(cells).grid;
}

@("table.layout.resolveColumnWidths.seamAndCaps")
@safe pure unittest
{
    // naturals are per-anchor inputs now — the core never measures content.
    auto g = testGrid([[Cell("aa"), Cell("b")], [Cell("c"), Cell("dddd")]]);
    const naturals = [size_t(2), 1, 1, 4];
    assert(resolveColumnWidths(g, TableProps(), naturals) == [2, 4]);
    assert(resolveColumnWidths(g,
        TableProps(columnMinWidths: [5]), naturals) == [5, 4]);
    assert(resolveColumnWidths(g,
        TableProps(columnMaxWidths: [0, 2]), naturals) == [2, 2]);
    // Total cap: frame = 2*2 gutters + 1 separator + 2 borders = 7; shrink
    // widest-first (leftmost on a tie) to fit 10.
    assert(resolveColumnWidths(g, TableProps(maxWidth: 10), naturals) == [1, 2]);
}

@("table.layout.resolveColumnWidths.colspanDistribution")
@safe pure unittest
{
    auto g = testGrid([[Cell("xxxxxxx", colSpan: 2)], [Cell("a"), Cell("b")]]);
    // The span absorbs 2 gutters + 1 separator; the remaining deficit of 2
    // spreads 1 per member column.
    assert(resolveColumnWidths(g, TableProps(), [size_t(7), 1, 1]) == [2, 2]);
}

@("table.layout.resolveRowHeights.seamAndRowspanGrowth")
@safe pure unittest
{
    auto g = testGrid([[Cell("A", rowSpan: 2), Cell("B")], [Cell("C")]]);
    assert(resolveRowHeights(g, [size_t(1), 1, 1]) == [1, 1]);
    // A 3-line rowspan cell grows its bands (remainder to the earlier row).
    assert(resolveRowHeights(g, [size_t(3), 1, 1]) == [2, 1]);
}

@("table.layout.decimalPadsFor.tailAggregation")
@safe pure unittest
{
    import sparkles.base.text.width : Align;

    auto g = testGrid([[Cell("1.5")], [Cell("23.25")], [Cell("7")]]);
    const p = TableProps(columnAligns: [Align.decimal]);
    // tails: width after the last dot; size_t.max = no dot.
    const pads = decimalPadsFor(g, p, [size_t(1), 2, size_t.max]);
    assert(pads == [1, 0, 3]); // maxTail 2: 1.5 pads 1, 23.25 pads 0, dotless 7 pads 3
    assert(decimalPadsFor(g, TableProps(), [size_t(1), 2, size_t.max]) is null);
}

@("table.layout.walkBodyLines.rowspanValignAndRules")
@safe pure unittest
{
    import std.algorithm : count, filter;

    // A(rowSpan 2, middle) | B  over  C(2 lines), with row separators: output
    // lines are top(0) body(1) rule(2) body(3) body(4) bottom(5).
    auto g = testGrid([
        [Cell("A", rowSpan: 2, valign: VAlign.middle), Cell("B")],
        [Cell("C")],
    ]);
    const p = TableProps(rowSeparators: true);
    const widths = [size_t(1), 1];
    const heights = resolveRowHeights(g, [size_t(1), 1, 2]);
    assert(heights == [1, 2]);
    const walk = walkBodyLines(g, p, widths, heights, [size_t(1), 1, 2]);

    // One field per covering anchor per body line: 2 fields on each of 3 lines.
    assert(walk.fields.length == 6);
    // A's single content line lands on the middle of its 3-line extent
    // (line 3, the first text line of row 1), blank above and below.
    foreach (f; walk.fields.filter!(f => f.anchor == 0))
        assert(f.hasContent == (f.line == 3));
    // Vertical rules: both borders on every body line, and the interior
    // separator (owners differ at boundary 1 in both bands).
    assert(walk.rules.count!(rc => rc.x == 0) == 3);
    assert(walk.rules.count!(rc => rc.x == 8) == 3);
    assert(walk.rules.count!(rc => rc.x == 4) == 3);
    assert(walk.rules.length == 9);
}

@("table.layout.anchorRects.rowspanSwallowsRuleLine")
@safe pure unittest
{
    auto g = testGrid([[Cell("A", rowSpan: 2), Cell("B")], [Cell("C")]]);
    const p = TableProps(rowSeparators: true);
    const rects = anchorRects(g, p, [size_t(1), 1], [size_t(1), 1]);
    // Lines: top(0) body(1) rule(2) body(3) bottom(4). A spans body+rule+body;
    // its rect is the field plus both gutters, borders excluded.
    assert(rects[0] == AnchorRect(1, 1, 3, 3));
    assert(rects[1] == AnchorRect(5, 1, 3, 1)); // B
    assert(rects[2] == AnchorRect(5, 3, 3, 1)); // C (the cursor skips A's band)
}

@("table.layout.ruleGlyphs.spanAwareRule")
@safe pure unittest
{
    import std.conv : to;

    auto g = testGrid([[Cell("A", rowSpan: 2), Cell("B")], [Cell("C")]]);
    const p = TableProps(rowSeparators: true);
    const widths = [size_t(1), 1];
    // The interior rule vanishes inside the rowspan: bare vertical at the left
    // border, a tee where the rule meets the separator, blank fill above A.
    assert(ruleGlyphs(g, p, widths, 1).to!string == "│   ├───┤");
    assert(ruleGlyphs(g, p, widths, 0).to!string == "╭───┬───╮");
    assert(ruleGlyphs(g, p, widths, 2).to!string == "╰───┴───╯");
    assert(tableWidth(p, widths, g.numCols) == 9);
}

@("table.layout.frameLineGlyphs.bandFrame")
@safe pure unittest
{
    import std.conv : to;

    auto g = testGrid([[Cell("A"), Cell("B")], [Cell("wide", colSpan: 2)]]);
    const widths = [size_t(1), 2];
    const p = TableProps();
    // Row 0 has the interior separator; row 1's colspan absorbs it.
    assert(frameLineGlyphs(g, p, widths, 0).to!string == "│   │    │");
    assert(frameLineGlyphs(g, p, widths, 1).to!string == "│        │");
}
