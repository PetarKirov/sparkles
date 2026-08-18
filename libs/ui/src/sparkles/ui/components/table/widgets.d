/++
The widget-emitting view of the span-capable table: the same layout core as
the string renderer (`sparkles.ui.components.table.layout`), materialized as a
`sparkles.ui` widget subtree instead of text lines — styled `TextSpan` cell
content (the identity channel flows through untouched), per-cell element keys
for hit-testing, semantic slots + resolved rule colors for theming, and an
optional top-border cutout (hue's whole-table copy button).

The tree is $(B core-geometry-driven): the root is a fixed-size `stack`, and
every rule run and cell subtree is positioned absolutely from the core's
`walkBodyLines`/`anchorRects` placement (a fit-sized wrapper whose
`padding.left/top` is the offset). Box-flow cannot express the layout's hard
cases — a rowspan cell's bands, and its content lines flowing $(I across) an
interior rule line that vanishes inside the cell — so the view places what the
core already solved rather than re-deriving it with `row`/`column` nesting.

Measurement is the toolkit's `cellsOf` and wrapping is `sparkles.ui.wrap` —
$(B not) the string view's grapheme-aware pair — because the display list and
the selection geometry hard-wire `cellsOf`; a table measured any other way
would misalign with its own painted spans. The two views therefore diverge on
CJK/emoji widths, by design.
+/
module sparkles.ui.components.table.widgets;

import std.conv : to;

import sparkles.base.term_color : RgbColor;
import sparkles.base.text.width : Align;

import sparkles.ui.canvas : RuleEdge;
import sparkles.ui.components.chrome : scrollbar, ScrollbarGlyphs, ScrollbarSpec;
import sparkles.ui.geometry : Insets, Point, SizeSpec, cellsOf;
import sparkles.ui.state : ScrollAxis;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind;
import sparkles.ui.wrap : TextSpan, TextWrap, wrapSpans;

import sparkles.ui.components.table.grid;
import sparkles.ui.components.table.layout;

/// One authored cell of the widget table: styled span content plus the same
/// extent/alignment controls as the string view's `Cell`, and an element key
/// for the keyed wrapper the view emits around the cell (`0` = anonymous).
/// The spans' `srcStart`/`srcEnd` survive wrapping untouched, so selection and
/// click-to-source keep working inside table cells.
struct SpanCell
{
    TextSpan[] spans;
    size_t colSpan = 1;             /// Number of columns this cell spans.
    size_t rowSpan = 1;             /// Number of rows this cell spans.
    Align halign = Align.inherit;   /// Per-cell override (else column/table default).
    VAlign valign = VAlign.inherit; /// ditto
    size_t key;                     /// `Widget.key` of the cell's keyed wrapper.
}

/// A right-edge top-border cutout (hue's `TBL6` whole-table copy button): the
/// last few fill cells of the top rule are replaced by `icon`, which carries
/// its own hit id and resolved color. Skipped when the last column is too
/// narrow to host the icon without covering a junction, or with `border` off.
struct TableCutout
{
    bool present;
    size_t hitId;  /// the icon widget's `Widget.hitId`
    TextSpan icon; /// e.g. `" ⧉ "` — its `cellsOf` width is the cutout width
    RgbColor fg;   /// resolved icon color (the theme channel), gated by `hasFg`
    bool hasFg;    /// ditto
}

/// How the widget view styles what it emits — the theme-channel inputs the
/// string view has no notion of.
struct TableWidgetStyle
{
    size_t hitId;                /// stamped on every rule/content run (0 = none)
    TextStyle baseStyle;         /// `textStyle` of the rule runs
    Slot cellSlot = Slot.inherit;/// slot of cell content runs
    Slot ruleSlot = Slot.border; /// slot of border/rule runs
    RgbColor ruleFg;             /// resolved rule color override, gated by `hasRuleFg`
    bool hasRuleFg;              /// ditto
    TableCutout cutout;          /// optional top-border cutout
    /// Wrap cell content to its resolved column field (the `maxWidth` /
    /// `columnMaxWidths` machinery needs this); off, a long line keeps its
    /// single-line width and the columns grow to fit it.
    bool wrapCells = true;
}

/// The framed-viewport input (hue's `TBL7`/`TBL8` model): when the table
/// exceeds `availWidth` and/or its interior exceeds `maxLines`, the view
/// emits a fence-style framed box instead of the plain grid — pinned frame
/// corners and side caps, the interior (cells + junction runs) scrolling as
/// one behind `clipX`/`clipY` viewports, the bottom border doubling as the
/// horizontal scrollbar (junctions dropped while it shows) and the right
/// border as the vertical track. Requires `TableProps.border`; scroll state
/// lives with the caller (offsets are passed in, bar hit ids name the
/// targets).
struct TableViewportSpec
{
    int availWidth;      /// available box width in cells (0 = no h viewport)
    int maxLines;        /// interior line clamp (0 = no vertical viewport)
    int x;               /// horizontal scroll offset, in interior cells
    int y;               /// vertical scroll offset, in interior lines
    size_t hBarHitId;    /// bottom-border bar hit id (0 → `style.hitId`)
    size_t vBarHitId;    /// right-border track hit id (0 → `style.hitId`)
    RgbColor hThumbFg;   /// resolved h-thumb color (hot logic is the caller's)
    bool hasHThumbFg;    /// ditto
    RgbColor vThumbFg;   /// ditto
    bool hasVThumbFg;    /// ditto
    /// Pin the header band (the `TableProps.headerRows` rows plus their
    /// heavy rule) below the top border while the body scrolls behind the
    /// vertical viewport — hue's `DSG2` (a data grid keeps its column names
    /// in sight). Sugar for `freezeTopRows = headerRows` (used only when
    /// `freezeTopRows` is 0).
    bool pinHeader;

    /// Freeze panes (the spreadsheet idiom), generalizing `pinHeader`: the
    /// first/last N grid rows and/or first/last N grid columns stay at the
    /// viewport edges while the interior scrolls — frozen rows still scroll
    /// horizontally, frozen columns still scroll vertically; only the
    /// corners are fully static. Each band includes its boundary rule when
    /// one is drawn. Rows engage only with the vertical viewport, columns
    /// only with the horizontal one; a side is ignored when its band would
    /// not fit the view, when the frozen counts meet or exceed the grid, or
    /// when a span crosses its boundary (the band must be separable). The
    /// scroll ranges are unchanged: a frozen band shortens the scrolling
    /// view by exactly the extent it occupies, so host clamps stay valid.
    size_t freezeTopRows;
    size_t freezeBottomRows;    /// ditto (e.g. a totals row)
    size_t freezeLeftColumns;   /// ditto (e.g. a record-number gutter)
    size_t freezeRightColumns;  /// ditto
}

/// What `buildTableWidgets` produced: the root node, the table's full content
/// extent in cells/lines, the framed box's outer size (equal to the content
/// extent when no viewport engaged), and which bars were emitted.
struct TableWidgetResult
{
    uint root;
    int width;
    int height;
    int viewWidth;
    int viewHeight;
    bool hBar;
    bool vBar;
}

/// Build the table as a widget subtree in `b` and return its root. `cells` is
/// the dense authoring form (rows may be ragged; covered slots are omitted,
/// exactly like the string view's `Cell[][]`); `props` is the shared rendering
/// configuration — `title`/`footer` are not supported by this view and render
/// as plain rules.
TableWidgetResult buildTableWidgets(ref Builder b, in SpanCell[][] cells,
    TableProps props = TableProps.init,
    TableWidgetStyle style = TableWidgetStyle.init,
    TableViewportSpec vp = TableViewportSpec.init) @safe
{
    // Lower to the shared slot grid. Authored anchors keep authoring order
    // (row-major), so the flattened span/key lists parallel `grid.anchors`'
    // leading entries; implicit filler anchors follow and carry no content.
    auto plain = new Cell[][](cells.length);
    size_t authored;
    foreach (r, row; cells)
    {
        plain[r] = new Cell[](row.length);
        foreach (c, ref sc; row)
            plain[r][c] = Cell(null, sc.colSpan, sc.rowSpan, sc.halign, sc.valign);
        authored += row.length;
    }
    auto spansOf = new TextSpan[][](authored);
    auto keyOf = new size_t[](authored);
    {
        size_t i;
        foreach (row; cells)
            foreach (ref sc; row)
            {
                spansOf[i] = sc.spans.dup;
                keyOf[i] = sc.key;
                i++;
            }
    }
    const g = resolveGrid(plain).grid;
    if (g.numRows == 0 || g.numCols == 0)
        return TableWidgetResult(b.container(WidgetKind.column, null), 0, 0);

    static int measure(scope const(char)[] s) @safe pure nothrow @nogc
        => cast(int) cellsOf(s);

    // Unwrapped lines (breaks only at embedded '\n') give the naturals.
    auto lines = new TextSpan[][][](g.anchors.length);
    auto naturals = new size_t[](g.anchors.length);
    foreach (i, ref a; g.anchors)
    {
        if (i >= authored || !spansOf[i].length)
            continue;
        lines[i] = wrapSpans(spansOf[i], int.max, &measure);
        foreach (line; lines[i])
            naturals[i] = maxOf(naturals[i], lineWidth(line));
    }

    auto decimalPads = anchorDecimalPads(g, props, lines);
    const widths = resolveColumnWidths(g, props, naturals, decimalPads);

    // Re-wrap what no longer fits its resolved field (never when wrapping is
    // off — a long line then just defines the column width, so nothing can
    // overflow anyway).
    auto lineCounts = new size_t[](g.anchors.length);
    foreach (i, ref a; g.anchors)
    {
        if (!lines[i].length)
            continue;
        const f = contentField(a, widths, props, g.numCols);
        if (style.wrapCells && naturals[i] > f)
            lines[i] = wrapSpans(spansOf[i], f > 1 ? cast(int) f : 1, &measure);
        lineCounts[i] = lines[i].length;
    }
    const rowHeights = resolveRowHeights(g, lineCounts);

    const tableW = cast(int) tableWidth(props, widths, g.numCols);
    const walk = walkBodyLines(g, props, widths, rowHeights, lineCounts);
    const rects = anchorRects(g, props, widths, rowHeights);

    uint ruleRun(string text_, size_t hitId = 0)
    {
        Widget w = Widget(kind: WidgetKind.rich, spans: [
                TextSpan(text_, style.ruleSlot, style.baseStyle,
                    noBreak: true)],
            slot: style.ruleSlot, wrap: TextWrap.none,
            hitId: hitId ? hitId : style.hitId, textStyle: style.baseStyle);
        if (style.hasRuleFg)
        {
            w.fgOverride = style.ruleFg;
            w.hasFgOverride = true;
        }
        return b.add(w);
    }

    uint positioned(int x, int y, uint child)
        => b.container(WidgetKind.column, [child],
            padding: Insets(y, 0, 0, x));

    // Emission is one event list sorted by (line, x) — global reading order —
    // because `documentRows` aggregates per-row text in tree walk order: a
    // body row must contribute `│ a │ b │` left to right, not rules-then-
    // cells. An anchor emits its whole keyed wrapper at its first visible
    // content line (its rect's top line when it has none), so single-line
    // tables order perfectly and multi-line cells stay one addressable node.
    enum EmitKind : ubyte { ruleLine, ruleCell, anchor }
    static struct EmitEvent
    {
        size_t line, x;
        EmitKind kind;
        size_t index; // lattice row (ruleLine), walk.rules index, or anchor
    }

    EmitEvent[] events;
    size_t outLine;
    foreach (d; lineDescs(g, props, rowHeights))
    {
        scope (exit) outLine++;
        final switch (d.kind)
        {
            case LineKind.topRule:
                events ~= EmitEvent(outLine, 0, EmitKind.ruleLine, 0);
                break;
            case LineKind.rule:
                events ~= EmitEvent(outLine, 0, EmitKind.ruleLine, d.r);
                break;
            case LineKind.bottomRule:
                events ~= EmitEvent(outLine, 0, EmitKind.ruleLine, g.numRows);
                break;
            case LineKind.body:
            case LineKind.titlePlain:
            case LineKind.footerPlain:
                break; // body verticals come from the walk; titles unsupported
        }
    }
    const tableH = cast(int) outLine;

    foreach (ri, ref rc; walk.rules)
        events ~= EmitEvent(rc.line, rc.x, EmitKind.ruleCell, ri);

    // An anchor's emission point: its first contentful line (rect top for an
    // empty cell), at the rect's x.
    auto anchorLine = new size_t[](authored);
    foreach (i; 0 .. authored)
        anchorLine[i] = rects[i].y;
    auto seen = new bool[](authored);
    foreach (ref fp; walk.fields)
        if (fp.hasContent && fp.anchor < authored && !seen[fp.anchor])
        {
            seen[fp.anchor] = true;
            anchorLine[fp.anchor] = fp.line;
        }
    foreach (i; 0 .. authored)
        events ~= EmitEvent(anchorLine[i], rects[i].x, EmitKind.anchor, i);

    import std.algorithm : sort;

    events.sort!((a, b) => a.line != b.line ? a.line < b.line : a.x < b.x);

    // Content lines per anchor, prebuilt so the event walk emits whole cells.
    auto cellParts = new uint[][](authored);
    foreach (ref fp; walk.fields)
    {
        if (!fp.hasContent || fp.anchor >= authored)
            continue;
        const a = g.anchors[fp.anchor];
        Widget runW = Widget(kind: WidgetKind.rich,
            spans: lines[fp.anchor][fp.lineInCell].dup,
            hitId: style.hitId, slot: style.cellSlot,
            textStyle: style.baseStyle);
        const run = b.add(runW);

        const al = anchorAlign(a, props);
        const dpad = decimalPads.length ? decimalPads[fp.anchor] : 0;
        Widget alignW = Widget(kind: WidgetKind.column, children: [run],
            width: SizeSpec.fixed(cast(int) fp.width),
            alignX: al == Align.right || al == Align.decimal ? Alignment.end
                : al == Align.center ? Alignment.center
                : Alignment.start);
        if (dpad > 0 && dpad < fp.width)
            alignW.padding = Insets(0, cast(int) dpad, 0, 0);
        const rect = rects[fp.anchor];
        cellParts[fp.anchor] ~= positioned(
            cast(int)(fp.x - rect.x), cast(int)(fp.line - rect.y),
            b.add(alignW));
    }

    // Does a viewport engage? Framing needs the border (the caps ARE frame
    // glyphs) and a real interior on both axes.
    const interiorLines = tableH - 2;
    const hOver = vp.availWidth > 2 && tableW > vp.availWidth && props.border
        && interiorLines > 0;
    const shownLines = vp.maxLines > 0 && interiorLines > vp.maxLines
        ? vp.maxLines : interiorLines;
    const vOver = shownLines < interiorLines && props.border && tableW > 2;
    const framed = hOver || vOver;

    const interiorW = tableW - 2;
    const viewW = hOver ? vp.availWidth : tableW;
    const viewInnerW = viewW - 2;
    int sx = vp.x, sy = vp.y;
    if (sx > interiorW - viewInnerW)
        sx = interiorW - viewInnerW;
    if (sx < 0)
        sx = 0;
    if (sy > interiorLines - shownLines)
        sy = interiorLines - shownLines;
    if (sy < 0)
        sy = 0;

    const iconW = cast(int) cellsOf(style.cutout.icon.text);
    const cutout = style.cutout.present && props.border && iconW > 0
        && widths[g.numCols - 1] + 2 >= iconW;

    uint cutoutIcon()
    {
        Widget iconWdg = Widget(kind: WidgetKind.rich,
            spans: [style.cutout.icon],
            slot: style.cutout.icon.slot, wrap: TextWrap.none,
            hitId: style.cutout.hitId, textStyle: style.baseStyle);
        if (style.cutout.hasFg)
        {
            iconWdg.fgOverride = style.cutout.fg;
            iconWdg.hasFgOverride = true;
        }
        return b.add(iconWdg);
    }

    if (!framed)
    {
        uint[] parts;
        foreach (ref ev; events)
        {
            const y = cast(int) ev.line;
            final switch (ev.kind)
            {
                case EmitKind.ruleLine:
                    const glyphs = ruleGlyphs(g, props, widths, ev.index);
                    if (ev.index == 0 && cutout)
                    {
                        // `TBL6`: the icon replaces the last fill cells before
                        // the corner; the junctions stay untouched.
                        parts ~= positioned(0, y, b.container(WidgetKind.row, [
                            ruleRun(glyphs[0 .. $ - 1 - iconW].to!string),
                            cutoutIcon(),
                            ruleRun(glyphs[$ - 1 .. $].to!string),
                        ]));
                    }
                    else
                        parts ~= positioned(0, y, ruleRun(glyphs.to!string));
                    break;
                case EmitKind.ruleCell:
                    parts ~= positioned(cast(int) ev.x, y,
                        ruleRun(walk.rules[ev.index].glyph.to!string));
                    break;
                case EmitKind.anchor:
                    const rect = rects[ev.index];
                    Widget cellW = Widget(kind: WidgetKind.stack,
                        children: cellParts[ev.index],
                        width: SizeSpec.fixed(cast(int) rect.w),
                        height: SizeSpec.fixed(cast(int) rect.h),
                        key: keyOf[ev.index]);
                    parts ~= positioned(cast(int) rect.x, cast(int) rect.y,
                        b.add(cellW));
                    break;
            }
        }

        Widget root = Widget(kind: WidgetKind.stack, children: parts,
            width: SizeSpec.fixed(tableW), height: SizeSpec.fixed(tableH));
        return TableWidgetResult(b.add(root), tableW, tableH,
            viewWidth: tableW, viewHeight: tableH);
    }

    // ── The framed box: pinned caps, scrolled interior ──────────────────────
    // Interior coordinates drop the frame column/row: everything between the
    // borders — cells, inner `│` rules, and the interior `├─┼─┤` rule lines —
    // moves as one offset behind the clip; the side caps (each line's first
    // and last frame glyph) pin at the box edges so the frame stays whole.

    // ── Freeze panes (`vp.freeze*` / `pinHeader`) ───────────────────────────
    // Grid-level freeze counts resolve to interior extents: `topLines`/
    // `botLines` in interior lines, `leftW`/`rightW` in interior cells; a
    // band includes its boundary rule (it lies on the band's side of the
    // first frozen/scrolling row or column). All zero → the plain framed
    // emission below is byte-identical to the pre-freeze one.
    size_t fTop = vp.freezeTopRows, fBot = vp.freezeBottomRows;
    size_t fLeft = vp.freezeLeftColumns, fRight = vp.freezeRightColumns;
    if (vp.pinHeader && fTop == 0)
        fTop = props.headerRows;
    if (!vOver)
        fTop = fBot = 0;
    if (!hOver)
        fLeft = fRight = 0;
    if (fTop + fBot >= g.numRows)
        fTop = fBot = 0;
    if (fLeft + fRight >= g.numCols)
        fLeft = fRight = 0;
    // A span crossing a freeze boundary makes that band inseparable.
    bool rowBoundaryCrossed(size_t boundary)
    {
        foreach (ref a; g.anchors)
            if (a.row < boundary && a.row + a.rowSpan > boundary)
                return true;
        return false;
    }

    bool colBoundaryCrossed(size_t boundary)
    {
        foreach (ref a; g.anchors)
            if (a.col < boundary && a.col + a.colSpan > boundary)
                return true;
        return false;
    }

    if (fTop > 0 && rowBoundaryCrossed(fTop))
        fTop = 0;
    if (fBot > 0 && rowBoundaryCrossed(g.numRows - fBot))
        fBot = 0;
    if (fLeft > 0 && colBoundaryCrossed(fLeft))
        fLeft = 0;
    if (fRight > 0 && colBoundaryCrossed(g.numCols - fRight))
        fRight = 0;

    // The first interior line of grid row `row` (its band's top — any rule
    // at the boundary lies above it and lands in the band above).
    int interiorTopLine(size_t row)
    {
        size_t best = size_t.max;
        foreach (i, ref a; g.anchors)
            if (a.row == row && i < rects.length && rects[i].y < best)
                best = rects[i].y;
        return best == size_t.max ? -1 : cast(int) best - 1;
    }

    // Interior x of grid column `c`'s content field (after its lead gutter).
    int colContentX(size_t c)
    {
        int x = 1;
        foreach (j; 0 .. c)
            x += cast(int) widths[j] + 2 + cast(int) sepWidth(props, j + 1, g.numCols);
        return x;
    }

    int topLines = 0, botStart = interiorLines;
    if (fTop > 0)
    {
        topLines = interiorTopLine(fTop);
        if (topLines <= 0)
            topLines = 0;
    }
    if (fBot > 0)
    {
        const rowTop = interiorTopLine(g.numRows - fBot);
        if (rowTop > 0)
        {
            botStart = rowTop;
            // Pull the boundary rule (drawn just above the band) inside it.
            foreach (ref ev; events)
                if (ev.kind == EmitKind.ruleLine && ev.index == g.numRows - fBot)
                {
                    botStart = cast(int) ev.line - 1;
                    break;
                }
        }
    }
    if (topLines + (interiorLines - botStart) >= shownLines)
    {
        topLines = 0;
        botStart = interiorLines;
    }
    const botLines = interiorLines - botStart;
    const midShown = shownLines - topLines - botLines;
    const midContentLines = interiorLines - topLines - botLines;

    int leftW = 0, rightStart = interiorW;
    if (fLeft > 0)
        leftW = colContentX(fLeft) - 1;
    if (fRight > 0)
        rightStart = colContentX(g.numCols - fRight) - 1
            - cast(int) sepWidth(props, g.numCols - fRight, g.numCols);
    if (leftW + (interiorW - rightStart) >= viewInnerW)
    {
        leftW = 0;
        rightStart = interiorW;
    }
    const rightW = interiorW - rightStart;
    const centerViewW = viewInnerW - leftW - rightW;
    const centerContentW = interiorW - leftW - rightW;

    // ── Partition the interior into the 3×3 panes ───────────────────────────
    // paneParts[rowBand][colBand]; a full-width rule run splits at the
    // column-band edges, point items assign by position, cells by their rect
    // (the crossing guards made bands cell-aligned).
    uint[][3][3] paneParts;
    int rowBandOf(int li) => li < topLines ? 0 : li < botStart ? 1 : 2;
    int colBandOf(int x) => x < leftW ? 0 : x < rightStart ? 1 : 2;
    int rowBandY0(int rb) => rb == 0 ? 0 : rb == 1 ? topLines : botStart;
    int colBandX0(int cb) => cb == 0 ? 0 : cb == 1 ? leftW : rightStart;

    void addInterior(int x, int li, uint id)
    {
        const rb = rowBandOf(li), cb = colBandOf(x);
        paneParts[rb][cb] ~= positioned(x - colBandX0(cb), li - rowBandY0(rb), id);
    }

    void addRuleLine(int li, in dchar[] run) // `run` = interior glyphs
    {
        const rb = rowBandOf(li);
        const y = li - rowBandY0(rb);
        if (leftW > 0)
            paneParts[rb][0] ~= positioned(0, y, ruleRun(run[0 .. leftW].to!string));
        paneParts[rb][1] ~= positioned(0, y,
            ruleRun(run[leftW .. rightStart].to!string));
        if (rightW > 0)
            paneParts[rb][2] ~= positioned(0, y,
                ruleRun(run[rightStart .. $].to!string));
    }

    auto leftCapGlyph = new dchar[](interiorLines);
    auto rightCapGlyph = new dchar[](interiorLines);
    leftCapGlyph[] = props.glyphs.verticalLine;
    rightCapGlyph[] = props.glyphs.verticalLine;
    dchar[] topGlyphs, bottomGlyphs;

    foreach (ref ev; events)
    {
        final switch (ev.kind)
        {
            case EmitKind.ruleLine:
                auto glyphs = ruleGlyphs(g, props, widths, ev.index);
                if (ev.index == 0)
                    topGlyphs = glyphs;
                else if (ev.index == g.numRows)
                    bottomGlyphs = glyphs;
                else
                {
                    const li = cast(int) ev.line - 1;
                    leftCapGlyph[li] = glyphs[0];
                    rightCapGlyph[li] = glyphs[$ - 1];
                    addRuleLine(li, glyphs[1 .. $ - 1]);
                }
                break;
            case EmitKind.ruleCell:
                const rc = walk.rules[ev.index];
                const li = cast(int) rc.line - 1;
                if (rc.x == 0)
                    leftCapGlyph[li] = rc.glyph;
                else if (rc.x + 1 == tableW)
                    rightCapGlyph[li] = rc.glyph;
                else
                    addInterior(cast(int) rc.x - 1, li,
                        ruleRun(rc.glyph.to!string));
                break;
            case EmitKind.anchor:
                const rect = rects[ev.index];
                Widget cellW = Widget(kind: WidgetKind.stack,
                    children: cellParts[ev.index],
                    width: SizeSpec.fixed(cast(int) rect.w),
                    height: SizeSpec.fixed(cast(int) rect.h),
                    key: keyOf[ev.index]);
                addInterior(cast(int) rect.x - 1, cast(int) rect.y - 1,
                    b.add(cellW));
                break;
        }
    }

    uint capSegment(in dchar[] caps, bool clip, int shown)
    {
        auto runs = new uint[](0);
        foreach (ch; caps)
            runs ~= ruleRun(ch.to!string);
        Widget col = Widget(kind: WidgetKind.column, children: runs,
            width: SizeSpec.fixed(1), clipY: clip,
            childOffset: Point(0, clip ? sy : 0));
        if (clip)
            col.height = SizeSpec.fixed(shown);
        return b.add(col);
    }

    // A top/bottom border: static segments over frozen columns (junctions
    // kept — those columns never move), the center segment scrolling behind
    // a one-line clip when hOver. The `TBL6` cutout pins before the
    // top-right corner, carved from whichever segment owns that edge.
    uint borderRow(in dchar[] glyphs, bool withCutout)
    {
        const run = glyphs[1 .. $ - 1];
        uint[] parts = [ruleRun(glyphs[0 .. 1].to!string)];
        if (leftW > 0)
            parts ~= ruleRun(run[0 .. leftW].to!string);
        auto centerRun = run[leftW .. rightStart];
        auto rightRun = run[rightStart .. $];
        const carve = withCutout ? iconW : 0;
        if (hOver)
        {
            const window = centerViewW - (rightW > 0 ? 0 : carve);
            const mid = ruleRun(centerRun.to!string);
            Widget clip = Widget(kind: WidgetKind.column, children: [mid],
                clipX: true, childOffset: Point(sx, 0),
                width: SizeSpec.fixed(window),
                height: SizeSpec.fixed(1));
            parts ~= b.add(clip);
        }
        else
            parts ~= ruleRun(centerRun.to!string);
        if (rightW > 0)
            parts ~= ruleRun(rightRun[0 .. $ - carve].to!string);
        if (withCutout)
            parts ~= cutoutIcon();
        parts ~= ruleRun(glyphs[$ - 1 .. $].to!string);
        return b.container(WidgetKind.row, parts);
    }

    uint top = borderRow(topGlyphs, cutout);

    uint bottom;
    if (hOver)
    {
        // The fence idiom: the bottom border IS the horizontal scrollbar —
        // a plain fill under one semantic leaf spanning the scrolling
        // center; frozen-column segments keep their real junction glyphs.
        const run = bottomGlyphs[1 .. $ - 1];
        const fill = ruleRun(repeatGlyph(props.glyphs.horizontalLine,
            centerViewW));
        const bar = scrollbar(b, ScrollbarSpec(
            content: centerContentW,
            viewport: centerViewW,
            offset: sx,
            axis: ScrollAxis.horizontal,
            glyphs: ScrollbarGlyphs('━', props.glyphs.horizontalLine),
            edge: RuleEdge.centerY,
            hasEdge: true,
            hitId: vp.hBarHitId ? vp.hBarHitId : style.hitId,
            trackFg: style.ruleFg,
            hasTrackFg: style.hasRuleFg,
            thumbFg: vp.hThumbFg,
            hasThumbFg: vp.hasHThumbFg,
        ), centerViewW);
        const track = b.add(Widget(kind: WidgetKind.stack,
            children: [fill, bar], width: SizeSpec.fixed(centerViewW),
            height: SizeSpec.fixed(1)));
        uint[] parts = [ruleRun(bottomGlyphs[0 .. 1].to!string)];
        if (leftW > 0)
            parts ~= ruleRun(run[0 .. leftW].to!string);
        parts ~= track;
        if (rightW > 0)
            parts ~= ruleRun(run[rightStart .. $].to!string);
        parts ~= ruleRun(bottomGlyphs[$ - 1 .. $].to!string);
        bottom = b.container(WidgetKind.row, parts);
    }
    else
        bottom = borderRow(bottomGlyphs, false);

    // The vertical track for the scrolling strip (fenceVTrack's shape).
    uint vTrack(int contentLines, int shown)
    {
        auto trackCells = new uint[](0);
        foreach (_; 0 .. shown)
            trackCells ~= ruleRun(props.glyphs.verticalLine.to!string);
        const base = b.add(Widget(kind: WidgetKind.column,
            children: trackCells, width: SizeSpec.fixed(1)));
        const vbar = scrollbar(b, ScrollbarSpec(
            content: contentLines,
            viewport: shown,
            offset: sy,
            axis: ScrollAxis.vertical,
            glyphs: ScrollbarGlyphs('┃', props.glyphs.verticalLine),
            edge: RuleEdge.centerX,
            hasEdge: true,
            hitId: vp.vBarHitId ? vp.vBarHitId : style.hitId,
            trackFg: style.ruleFg,
            hasTrackFg: style.hasRuleFg,
            thumbFg: vp.vThumbFg,
            hasThumbFg: vp.hasVThumbFg,
        ), shown);
        return b.add(Widget(kind: WidgetKind.stack,
            children: [base, vbar], width: SizeSpec.fixed(1),
            height: SizeSpec.fixed(shown)));
    }

    // ── Assemble the strips: each row band is [left cap, panes, right edge];
    // the middle strip scrolls vertically (its caps clip with `sy`, its right
    // edge is the track when vOver), the frozen strips never do. A pane
    // clips horizontally only in the center column band.
    uint pane(int rb, int cb)
    {
        const w0 = cb == 0 ? leftW : cb == 1 ? centerContentW : rightW;
        const h0 = rb == 0 ? topLines : rb == 1 ? midContentLines : botLines;
        const boxW = cb == 1 ? centerViewW : w0;
        const boxH = rb == 1 ? midShown : h0;
        const inner = b.add(Widget(kind: WidgetKind.stack,
            children: paneParts[rb][cb], width: SizeSpec.fixed(w0),
            height: SizeSpec.fixed(h0)));
        const cx = cb == 1 && hOver, cy = rb == 1 && vOver;
        return b.add(Widget(kind: WidgetKind.column, children: [inner],
            clipX: cx, clipY: cy,
            childOffset: Point(cx ? sx : 0, cy ? sy : 0),
            width: SizeSpec.fixed(boxW), height: SizeSpec.fixed(boxH)));
    }

    uint[] frameRows;
    foreach (rb; 0 .. 3)
    {
        const h0 = rb == 0 ? topLines : rb == 1 ? midContentLines : botLines;
        if (h0 <= 0)
            continue;
        const y0 = rowBandY0(rb);
        const y1 = rb == 0 ? topLines : rb == 1 ? botStart : interiorLines;
        uint[] parts = [capSegment(leftCapGlyph[y0 .. y1], rb == 1 && vOver,
            midShown)];
        if (leftW > 0)
            parts ~= pane(rb, 0);
        parts ~= pane(rb, 1);
        if (rightW > 0)
            parts ~= pane(rb, 2);
        parts ~= rb == 1 && vOver ? vTrack(midContentLines, midShown)
            : capSegment(rightCapGlyph[y0 .. y1], false, 0);
        frameRows ~= b.container(WidgetKind.row, parts);
    }

    Widget root = Widget(kind: WidgetKind.column,
        children: [top] ~ frameRows ~ [bottom],
        width: SizeSpec.fixed(viewW),
        height: SizeSpec.fixed(shownLines + 2));
    return TableWidgetResult(b.add(root), tableW, tableH,
        viewWidth: viewW, viewHeight: shownLines + 2,
        hBar: hOver, vBar: vOver);
}

private string repeatGlyph(dchar g, int n) @safe pure
{
    import std.array : appender;

    auto s = appender!string;
    foreach (_; 0 .. n)
        s ~= g;
    return s[];
}

/// The widget view's decimal tails: cells of one wrapped line after its last
/// `'.'`, measured with `cellsOf` (span metadata carries the styling, so the
/// text itself is escape-free — no stripping needed).
private size_t[] anchorDecimalPads(in SlotGrid g, in TableProps p,
    in TextSpan[][][] lines) @safe pure
{
    bool any = false;
    foreach (c; 0 .. g.numCols)
        any = any || effectiveAlign(c, p) == Align.decimal;
    if (!any)
        return null;

    auto tails = new size_t[](g.anchors.length);
    foreach (i, cellLines; lines)
        tails[i] = cellLines.length == 1
            ? decimalTailCells(cellLines[0]) : size_t.max;
    return decimalPadsFor(g, p, tails);
}

/// ditto
private size_t decimalTailCells(in TextSpan[] line) @safe pure nothrow @nogc
{
    size_t dotSpan = size_t.max, dotOff;
    foreach (si, ref s; line)
        foreach (i, char ch; s.text)
            if (ch == '.')
            {
                dotSpan = si;
                dotOff = i;
            }
    if (dotSpan == size_t.max)
        return size_t.max;
    size_t w = cellsOf(line[dotSpan].text[dotOff + 1 .. $]);
    foreach (ref s; line[dotSpan + 1 .. $])
        w += cellsOf(s.text);
    return w;
}

private size_t lineWidth(in TextSpan[] line) @safe pure nothrow @nogc
{
    size_t w;
    foreach (ref s; line)
        w += cellsOf(s.text);
    return w;
}

private size_t maxOf(size_t a, size_t b) @safe pure nothrow @nogc
    => a > b ? a : b;

version (unittest)
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Constraints, Rect;
    import sparkles.ui.interp.cells : CellGrid;
    import sparkles.ui.interp.immediate : paint;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : keyedRects;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui.widget : WidgetTree;

    import sparkles.ui.components.table.render : drawTable;

    /// One plain span per cell — the span-free A/B form.
    private SpanCell[][] plainCells(in string[][] rows) @safe
    {
        auto out_ = new SpanCell[][](rows.length);
        foreach (r, row; rows)
        {
            out_[r] = new SpanCell[](row.length);
            foreach (c, s; row)
                out_[r][c] = SpanCell([TextSpan(s)]);
        }
        return out_;
    }

    /// Render the widget table headlessly and dump the glyphs, per-row
    /// right-trimmed — directly comparable with `drawTable`'s lines.
    private string renderWidgetTable(in SpanCell[][] cells,
        TableProps props = TableProps.init,
        TableWidgetStyle style = TableWidgetStyle.init) @safe
    {
        auto b = Builder();
        const res = buildTableWidgets(b, cells, props, style);
        auto tree = b.finish(res.root);
        auto frames = layout(tree, Constraints(maxW: res.width));
        const fg = RgbColor(0xcc, 0xcc, 0xcc), bg = RgbColor(0x1e, 0x1e, 0x1e);
        auto grid = CellGrid(res.width, res.height, fg, bg);
        paint(grid, buildDisplayList(tree, frames, defaultTwoslashPalette(),
            fg, bg));

        import std.utf : encode;

        string text;
        foreach (y; 0 .. grid.height)
        {
            size_t lineEnd = text.length;
            foreach (x; 0 .. grid.width)
            {
                char[4] buf;
                const n = encode(buf, grid.cells[y * grid.width + x].glyph);
                text ~= buf[0 .. n];
                if (grid.cells[y * grid.width + x].glyph != ' ')
                    lineEnd = text.length;
            }
            text = text[0 .. lineEnd];
            text ~= '\n';
        }
        return text;
    }

    /// `drawTable` with each line right-trimmed, for glyph-dump comparison.
    private string trimmedDrawTable(Cell[][] cells, TableProps props)
    {
        import std.algorithm : map;
        import std.array : join;
        import std.string : splitLines, stripRight;

        return drawTable(cells, props)
            .splitLines.map!(l => l.stripRight ~ "\n").join;
    }

    private void checkGlyphParity(in string[][] rows, TableProps props,
        string file = __FILE__, size_t line = __LINE__)
    {
        import std.conv : text;
        import core.exception : AssertError;

        auto plain = new Cell[][](rows.length);
        foreach (r, row; rows)
        {
            plain[r] = new Cell[](row.length);
            foreach (c, s; row)
                plain[r][c] = Cell(s);
        }
        const expected = trimmedDrawTable(plain, props);
        const actual = renderWidgetTable(plainCells(rows), props);
        if (actual != expected)
            throw new AssertError(
                text("widget/string table mismatch:\n", actual, "----\n", expected),
                file, line);
    }
}

@("table.widgets.glyphParityWithDrawTable")
@system unittest
{
    const rows = [
        ["Name", "Qty", "Price"],
        ["Apples", "10", "1.50"],
        ["Pears", "7", "0.75"],
    ];
    checkGlyphParity(rows, TableProps());
    checkGlyphParity(rows, TableProps(headerRows: 1));
    checkGlyphParity(rows, TableProps(headerRows: 1, rowSeparators: true));
    checkGlyphParity(rows, TableProps(headerRows: 1, headerCols: 1));
    checkGlyphParity(rows, TableProps(border: false));
    checkGlyphParity(rows, TableProps(columnSeparators: false));
    checkGlyphParity(rows,
        TableProps(columnAligns: [Align.left, Align.right, Align.center]));
    checkGlyphParity(rows, TableProps(glyphs: presetGlyphs("ascii"),
        headerRows: 1));
    checkGlyphParity([["only"]], TableProps());
}

@("table.widgets.glyphParityWithDrawTable.spansAndWrap")
@system unittest
{
    // A colspan header over two columns, and a maxWidth that wraps content:
    // both views share the solved geometry, so the junctions and the wrapped
    // line breaks land on the same cells (ASCII content: the measures agree).
    auto spanned = [
        [Cell("wide header", colSpan: 2)],
        [Cell("a"), Cell("b")],
    ];
    auto widget = [
        [SpanCell([TextSpan("wide header")], colSpan: 2)],
        [SpanCell([TextSpan("a")]), SpanCell([TextSpan("b")])],
    ];
    assert(renderWidgetTable(widget, TableProps(headerRows: 1))
        == trimmedDrawTable(spanned, TableProps(headerRows: 1)));

    auto tall = [
        [Cell("A", rowSpan: 2), Cell("first second third")],
        [Cell("x")],
    ];
    auto tallW = [
        [SpanCell([TextSpan("A")], rowSpan: 2),
            SpanCell([TextSpan("first second third")])],
        [SpanCell([TextSpan("x")])],
    ];
    auto p = TableProps(maxWidth: 16);
    assert(renderWidgetTable(tallW, p) == trimmedDrawTable(tall, p));
}

@("table.widgets.keyedRectsOnePerCell")
@safe unittest
{
    auto cells = [
        [SpanCell([TextSpan("a")], key: 11), SpanCell([TextSpan("bb")], key: 12)],
        [SpanCell([TextSpan("c")], key: 21), SpanCell(null, key: 22)],
    ];
    auto b = Builder();
    const res = buildTableWidgets(b, cells);
    auto tree = b.finish(res.root);
    auto frames = layout(tree, Constraints(maxW: res.width));
    const rects = keyedRects(tree, frames);

    // Exactly one keyed rect per authored cell — the empty cell included —
    // covering field + both gutters, one line tall.
    assert(rects.length == 4);
    size_t[] keys;
    foreach (kr; rects)
        keys ~= kr.key;
    assert(keys == [11, 12, 21, 22]);
    foreach (kr; rects)
        assert(kr.rect.height == 1);
    assert(rects[0].rect == Rect(1, 1, 3, 1));  // "a": gutter+field(1)+gutter
    assert(rects[1].rect == Rect(5, 1, 4, 1));  // "bb"
    assert(rects[2].rect == Rect(1, 2, 3, 1));
    assert(rects[3].rect == Rect(5, 2, 4, 1));  // empty, still addressable
}

@("table.widgets.alignmentAndIdentity")
@safe unittest
{
    // Right alignment positions the run at the field's end, and the spans'
    // source identity survives the build (the selection channel).
    auto cells = [
        [SpanCell([TextSpan("head")]),
            SpanCell([TextSpan("v")], halign: Align.right)],
        [SpanCell([TextSpan("x", srcStart: 100, srcEnd: 101)]),
            SpanCell([TextSpan("12345")])],
    ];
    auto b = Builder();
    const res = buildTableWidgets(b, cells);
    auto tree = b.finish(res.root);
    auto frames = layout(tree, Constraints(maxW: res.width));

    // Find the "v" run and the identity-carrying "x" run.
    bool sawV, sawX;
    foreach (i, ref n; tree.nodes)
        if (n.kind == WidgetKind.rich && n.spans.length == 1)
        {
            if (n.spans[0].text == "v")
            {
                sawV = true;
                // columns: w0=4, w1=5 → col-1 field starts at x=9
                // (border+gutter+4+gutter+separator+gutter); right-aligned
                // 1-cell run sits at field start + (5 - 1).
                assert(frames[i].rect.x == 9 + 5 - 1);
            }
            if (n.spans[0].text == "x")
            {
                sawX = true;
                assert(n.spans[0].srcStart == 100 && n.spans[0].srcEnd == 101);
            }
        }
    assert(sawV && sawX);
}

@("table.widgets.documentRowsReadInOrder")
@safe unittest
{
    import sparkles.ui.state : documentRows;

    // documentRows appends in tree walk order, so a body row's extracted text
    // must interleave rules and cells left to right — the emission order
    // contract a screen reader / search index depends on.
    auto b = Builder();
    const res = buildTableWidgets(b, plainCells([["ab", "cd"]]));
    auto tree = b.finish(res.root);
    auto frames = layout(tree, Constraints(maxW: res.width));
    const rows = documentRows(tree, frames);
    assert(rows.length == 3);
    assert(rows[1].text == "│ab│cd│");
}

@("table.widgets.rowspanKeyedRectSpansRuleLine")
@safe unittest
{
    // A rowspan cell's keyed rect covers all its bands including the interior
    // rule line that vanishes inside it — one rect, one key, the whole area.
    auto cells = [
        [SpanCell([TextSpan("A")], rowSpan: 2, key: 1),
            SpanCell([TextSpan("B")], key: 2)],
        [SpanCell([TextSpan("C")], key: 3)],
    ];
    auto b = Builder();
    const res = buildTableWidgets(b, cells, TableProps(rowSeparators: true));
    auto tree = b.finish(res.root);
    auto frames = layout(tree, Constraints(maxW: res.width));
    const rects = keyedRects(tree, frames);
    assert(rects.length == 3);
    assert(rects[0].key == 1);
    assert(rects[0].rect == Rect(1, 1, 3, 3)); // body + rule + body
    assert(rects[1].rect == Rect(5, 1, 3, 1));
    assert(rects[2].rect == Rect(5, 3, 3, 1)); // the cursor skips A's band
}

@("table.widgets.valignMiddlePlacesTheRun")
@safe unittest
{
    // A(middle) spans two rows whose right neighbours are 1 + 2 lines tall:
    // A's single line lands on the middle output line of its 3-line extent.
    auto cells = [
        [SpanCell([TextSpan("A")], rowSpan: 2, valign: VAlign.middle),
            SpanCell([TextSpan("B")])],
        [SpanCell([TextSpan("line one\nline two")])],
    ];
    auto b = Builder();
    const res = buildTableWidgets(b, cells);
    auto tree = b.finish(res.root);
    auto frames = layout(tree, Constraints(maxW: res.width));
    foreach (i, ref n; tree.nodes)
        if (n.kind == WidgetKind.rich && n.spans.length == 1
            && n.spans[0].text == "A")
            assert(frames[i].rect.y == 2); // top(0) body(1) body(2) body(3)
}

@("table.widgets.decimalParityWithDrawTable")
@system unittest
{
    const rows = [
        ["item", "value"],
        ["a", "1.5"],
        ["b", "23.25"],
        ["c", "7"],
    ];
    checkGlyphParity(rows, TableProps(headerRows: 1,
        columnAligns: [Align.left, Align.decimal]));
}

@("table.widgets.viewport.frameStaysPinned")
@safe unittest
{
    // A 2-column table ~30 cells wide in a 16-cell box, scrolled 5 right:
    // the frame pins, the interior carries the offset, the cutout rides the
    // pinned top border.
    auto cells = plainCells([
        ["a rather long header", "second"],
        ["x", "y"],
    ]);
    TableWidgetStyle style = {
        cutout: TableCutout(present: true, hitId: 555,
            icon: TextSpan(" + ", Slot.gutter, noBreak: true)),
    };
    auto b = Builder();
    const res = buildTableWidgets(b, cells, TableProps(), style,
        TableViewportSpec(availWidth: 16, x: 5));
    assert(res.hBar && !res.vBar);
    assert(res.viewWidth == 16 && res.width > 16);

    auto tree = b.finish(res.root);
    auto frames = layout(tree, Constraints(maxW: 16));
    assert(frames[res.root].rect.width == 16);

    bool sawClip, sawIcon;
    foreach (i, ref n; tree.nodes)
    {
        if (n.clipX && n.childOffset.x == 5)
            sawClip = true;
        if (n.hitId == 555)
        {
            sawIcon = true;
            // Pinned: 3 cells ending just before the top-right corner.
            assert(frames[i].rect == Rect(16 - 4, 0, 3, 1));
        }
    }
    assert(sawClip && sawIcon);
}

@("table.widgets.viewport.freezePanes")
@safe unittest
{
    // Freeze one row top and bottom and the first column, with both
    // viewports engaged and offsets: the 3x3 pane grid — corners static,
    // frozen rows scrolling only horizontally, frozen columns only
    // vertically, the center both ways; the h-bar spans the scrolling
    // center segment only.
    auto rows = new string[][](8);
    rows[0] = ["id", "alpha column head", "beta column head", "gamma column"];
    foreach (r; 1 .. 7)
        rows[r] = ["r" ~ cast(char)('0' + r), "aaaaaaaaaaaa", "bbbbbbbbbbbb",
            "cccccccccccc"];
    rows[7] = ["Σ", "totals-a", "totals-b", "totals-c"];
    auto b = Builder();
    const res = buildTableWidgets(b, plainCells(rows),
        TableProps(headerRows: 1), TableWidgetStyle(),
        TableViewportSpec(availWidth: 30, maxLines: 6, x: 4, y: 1,
            freezeTopRows: 1, freezeBottomRows: 1, freezeLeftColumns: 1));
    assert(res.hBar && res.vBar);
    assert(res.viewWidth == 30 && res.viewHeight == 8);

    auto tree = b.finish(res.root);
    auto frames = layout(tree, Constraints(maxW: 30));
    assert(frames[res.root].rect.width == 30);
    assert(frames[res.root].rect.height == 8);

    bool sawCenter, sawHeadPane, sawGutterPane, sawTotalsText, sawGutterText;
    int clipXOnly, clipYOnly;
    foreach (i, ref n; tree.nodes)
    {
        if (n.clipX && n.clipY)
        {
            sawCenter = true;
            assert(n.childOffset == Point(4, 1));
        }
        else if (n.clipX && n.childOffset.x == 4)
            clipXOnly++; // top border seg + top/bottom center panes
        else if (n.clipY && n.childOffset.y == 1)
            clipYOnly++; // middle caps + middle left pane
        foreach (ref sp; n.spans)
        {
            if (sp.text == "id")
                sawHeadPane = true;
            if (sp.text == "r3")
                sawGutterText = true;
            if (sp.text == "totals-a")
                sawTotalsText = true;
        }
    }
    assert(sawCenter && sawHeadPane && sawGutterText && sawTotalsText);
    assert(clipXOnly == 3 && clipYOnly == 2);

    // The frozen corner cell ("id") lays out statically under the border.
    foreach (i, ref n; tree.nodes)
        foreach (ref sp; n.spans)
            if (sp.text == "id")
                assert(frames[i].rect.y == 1 && frames[i].rect.x <= 2);

    // A rowspan crossing the top freeze boundary disengages that band:
    // identical emission shape to the unfrozen run.
    auto spanCells = new SpanCell[][](4);
    spanCells[0] = [SpanCell([TextSpan("tall", Slot.inherit)], rowSpan: 2),
        SpanCell([TextSpan("b", Slot.inherit)])];
    spanCells[1] = [SpanCell([TextSpan("c", Slot.inherit)])];
    foreach (r; 2 .. 4)
        spanCells[r] = [SpanCell([TextSpan("x", Slot.inherit)]),
            SpanCell([TextSpan("y", Slot.inherit)])];
    auto b4 = Builder();
    const frozen = buildTableWidgets(b4, spanCells, TableProps(),
        TableWidgetStyle(), TableViewportSpec(maxLines: 3, freezeTopRows: 1));
    auto b5 = Builder();
    const plain = buildTableWidgets(b5, spanCells, TableProps(),
        TableWidgetStyle(), TableViewportSpec(maxLines: 3));
    assert(b4.finish(frozen.root).nodes.length
        == b5.finish(plain.root).nodes.length);
}

@("table.widgets.viewport.pinnedHeaderBand")
@safe unittest
{
    // headerRows:1 + pinHeader: the header row and its heavy rule split into
    // a non-vertically-scrolling band (interior lines 0–1 → pinLines 2); the
    // body scrolls below it in a shortened viewport, same total box height.
    auto rows = new string[][](9);
    rows[0] = ["colA", "colB"];
    foreach (r; 1 .. 9)
        rows[r] = ["a", "b"];
    auto b = Builder();
    const res = buildTableWidgets(b, plainCells(rows),
        TableProps(headerRows: 1), TableWidgetStyle(),
        TableViewportSpec(maxLines: 4, y: 2, vBarHitId: 800, pinHeader: true));
    assert(res.vBar && !res.hBar);
    assert(res.viewHeight == 6); // 4 interior lines + both borders

    auto tree = b.finish(res.root);
    auto frames = layout(tree, Constraints(maxW: 40));
    assert(frames[res.root].rect.height == 6);

    bool sawHeaderText, sawBodyClip, sawPinClip;
    foreach (i, ref n; tree.nodes)
    {
        foreach (ref sp; n.spans)
            if (sp.text == "colA")
            {
                sawHeaderText = true;
                // The header band sits directly under the top border and
                // does NOT carry the vertical offset.
                assert(frames[i].rect.y == 1);
            }
        if (n.clipY && n.childOffset.y == 2)
        {
            sawBodyClip = true;
            // bodyShown = shownLines(4) − pinLines(2).
            assert(frames[i].rect.height == 2);
        }
        if (!n.clipY && n.clipX)
            sawPinClip = true; // never engages here (no hOver): stays false
    }
    assert(sawHeaderText && sawBodyClip);
    assert(!sawPinClip);

    // pinHeader without headerRows is inert: identical emission shape.
    auto b2 = Builder();
    const plainRes = buildTableWidgets(b2, plainCells(rows), TableProps(),
        TableWidgetStyle(), TableViewportSpec(maxLines: 4, y: 2));
    auto b3 = Builder();
    const pinnedRes = buildTableWidgets(b3, plainCells(rows), TableProps(),
        TableWidgetStyle(), TableViewportSpec(maxLines: 4, y: 2, pinHeader: true));
    assert(b2.finish(plainRes.root).nodes.length
        == b3.finish(pinnedRes.root).nodes.length);
}

@("table.widgets.viewport.barsAreSemanticLeaves")
@safe unittest
{
    import sparkles.ui.state : hoverTargets;

    auto rows = new string[][](8);
    foreach (r; 0 .. 8)
        rows[r] = ["this row is quite wide indeed", "even wider than that"];
    auto b = Builder();
    const res = buildTableWidgets(b, plainCells(rows), TableProps(),
        TableWidgetStyle(),
        TableViewportSpec(availWidth: 20, maxLines: 4,
            hBarHitId: 700, vBarHitId: 800));
    assert(res.hBar && res.vBar);
    assert(res.viewHeight == 6); // 4 interior lines + both borders

    auto tree = b.finish(res.root);
    auto frames = layout(tree, Constraints(maxW: 20));
    auto targets = hoverTargets(tree, frames);

    int bars;
    Rect hRect, vRect;
    foreach (i, ref const n; tree.nodes)
    {
        if (n.kind != WidgetKind.scrollbar)
            continue;
        ++bars;
        assert(n.barContent > n.barViewport);
        if (n.hitId == 700)
            hRect = frames[i].rect;
        else
        {
            assert(n.hitId == 800);
            vRect = frames[i].rect;
            assert(frames[i].rect.width == 1 && frames[i].rect.height == 4);
        }
    }
    assert(bars == 2);

    bool hHit, vHit;
    foreach (ref const t; targets)
    {
        if (t.hitId == 700)
            hHit = t.rect == hRect;
        if (t.hitId == 800)
            vHit = t.rect == vRect;
    }
    assert(hHit && vHit,
        "the painted semantic track and its hit target share one frame");
}

@("table.widgets.viewport.fittingTableStaysUnframed")
@safe unittest
{
    auto b = Builder();
    const res = buildTableWidgets(b, plainCells([["a", "b"]]), TableProps(),
        TableWidgetStyle(), TableViewportSpec(availWidth: 60, maxLines: 10));
    assert(!res.hBar && !res.vBar);
    assert(res.viewWidth == res.width && res.viewHeight == res.height);
    auto tree = b.finish(res.root);
    foreach (ref const n; tree.nodes)
        assert(!n.clipX && !n.clipY && n.kind != WidgetKind.scrollbar);
}

@("table.widgets.cutoutPinsIconInTopBorder")
@safe unittest
{
    auto cells = plainCells([["alpha", "beta"], ["a", "b"]]);
    TableWidgetStyle style = {
        cutout: TableCutout(present: true, hitId: 999,
            icon: TextSpan(" + ", Slot.gutter, noBreak: true)),
    };
    auto b = Builder();
    const res = buildTableWidgets(b, cells, TableProps(), style);
    auto tree = b.finish(res.root);
    auto frames = layout(tree, Constraints(maxW: res.width));

    // The icon is its own hit target riding in the top border, 3 cells, ending
    // just before the pinned corner.
    bool sawIcon;
    foreach (i, ref n; tree.nodes)
        if (n.hitId == 999)
        {
            sawIcon = true;
            assert(frames[i].rect == Rect(res.width - 4, 0, 3, 1));
        }
    assert(sawIcon);

    // Too narrow for the icon (a zero-width last column's field is 2 cells):
    // the plain border comes back whole.
    auto b2 = Builder();
    const res2 = buildTableWidgets(b2, plainCells([[""]]), TableProps(), style);
    auto tree2 = b2.finish(res2.root);
    foreach (ref n; tree2.nodes)
        assert(n.hitId != 999);
}
