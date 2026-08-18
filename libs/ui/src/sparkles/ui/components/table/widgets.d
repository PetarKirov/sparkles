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

import sparkles.ui.geometry : Insets, SizeSpec, cellsOf;
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

/// What `buildTableWidgets` produced: the root node plus the table's full
/// content extent in cells/lines — the caller's input for embedding decisions
/// (e.g. wrapping the root in a clipping viewport when it exceeds a pane).
struct TableWidgetResult
{
    uint root;
    int width;
    int height;
}

/// Build the table as a widget subtree in `b` and return its root. `cells` is
/// the dense authoring form (rows may be ragged; covered slots are omitted,
/// exactly like the string view's `Cell[][]`); `props` is the shared rendering
/// configuration — `title`/`footer` are not supported by this view and render
/// as plain rules.
TableWidgetResult buildTableWidgets(ref Builder b, in SpanCell[][] cells,
    TableProps props = TableProps.init,
    TableWidgetStyle style = TableWidgetStyle.init) @safe
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

    uint[] parts;
    int tableH;

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

    // The lattice: whole-line runs for the rules, one 1-cell run per drawn
    // vertical on the body lines — never a run across a field or gutter, so
    // unpainted cells stay unpainted (the same coverage as per-line emission).
    size_t outLine;
    foreach (d; lineDescs(g, props, rowHeights))
    {
        scope (exit) outLine++;
        const y = cast(int) outLine;
        final switch (d.kind)
        {
            case LineKind.topRule:
                const glyphs = ruleGlyphs(g, props, widths, 0);
                const iconW = cast(int) cellsOf(style.cutout.icon.text);
                if (style.cutout.present && props.border && iconW > 0
                    && widths[g.numCols - 1] + 2 >= iconW)
                {
                    // `TBL6`: the icon replaces the last fill cells before the
                    // corner; the junctions stay untouched.
                    Widget iconWdg = Widget(kind: WidgetKind.rich,
                        spans: [style.cutout.icon],
                        slot: style.cutout.icon.slot, wrap: TextWrap.none,
                        hitId: style.cutout.hitId, textStyle: style.baseStyle);
                    if (style.cutout.hasFg)
                    {
                        iconWdg.fgOverride = style.cutout.fg;
                        iconWdg.hasFgOverride = true;
                    }
                    parts ~= positioned(0, y, b.container(WidgetKind.row, [
                        ruleRun(glyphs[0 .. $ - 1 - iconW].to!string),
                        b.add(iconWdg),
                        ruleRun(glyphs[$ - 1 .. $].to!string),
                    ]));
                }
                else
                    parts ~= positioned(0, y, ruleRun(glyphs.to!string));
                break;
            case LineKind.rule:
                parts ~= positioned(0, y,
                    ruleRun(ruleGlyphs(g, props, widths, d.r).to!string));
                break;
            case LineKind.bottomRule:
                parts ~= positioned(0, y,
                    ruleRun(ruleGlyphs(g, props, widths, g.numRows).to!string));
                break;
            case LineKind.body:
            case LineKind.titlePlain:
            case LineKind.footerPlain:
                break; // body verticals come from the walk; titles unsupported
        }
    }
    tableH = cast(int) outLine;

    foreach (ref rc; walk.rules)
        parts ~= positioned(cast(int) rc.x, cast(int) rc.line,
            ruleRun(rc.glyph.to!string));

    // The cell layer: one keyed wrapper per authored anchor, sized to the
    // anchor's rect (field + both gutters wide, every band tall), each visible
    // content line placed inside it as a fixed-width aligned single-line run.
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
    foreach (i; 0 .. authored)
    {
        const rect = rects[i];
        Widget cellW = Widget(kind: WidgetKind.stack,
            children: cellParts[i],
            width: SizeSpec.fixed(cast(int) rect.w),
            height: SizeSpec.fixed(cast(int) rect.h),
            key: keyOf[i]);
        parts ~= positioned(cast(int) rect.x, cast(int) rect.y, b.add(cellW));
    }

    Widget root = Widget(kind: WidgetKind.stack, children: parts,
        width: SizeSpec.fixed(tableW), height: SizeSpec.fixed(tableH));
    return TableWidgetResult(b.add(root), tableW, tableH);
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
