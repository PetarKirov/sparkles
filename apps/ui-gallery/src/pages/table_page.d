/**
The Table page: the span-capable table component, both views live.

One layout core solves the grid — column widths, row heights, junction glyphs
— and two views materialize it: `drawTable` emits text lines (the bench
tables, `apps/ci`, `apps/release`), and `buildTableWidgets` emits a widget
subtree (hue's markdown tables). The page renders the SAME data through both,
side by side, so their agreement is something a reader sees rather than
takes on faith; the framed demo below shows the `TBL7`/`TBL8` overflow
viewport — pinned frame, scrolled interior, the borders doubling as
scrollbars — driven from the keyboard.
*/
module pages.table_page;

import std.conv : text;
import std.string : splitLines;

import sparkles.base.text.width : Align;
import sparkles.input : Key, KeyEvent;
import sparkles.ui.components.table : builtinPresetNames, Cell, drawTable,
    presetGlyphs, TableProps, VAlign;
import sparkles.ui.components.table.widgets : buildTableWidgets, SpanCell,
    TableViewportSpec, TableWidgetStyle;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, TextSpan;
import sparkles.ui.wrap : TextWrap;

import kit;
import state : GalleryState, TableDemo;

@safe:

/// ditto
static immutable string[] keys = [
    "g glyphs", "r row rules", "s stub col", "[/] scroll", ",/. rows",
];

/// The showcase grid: a colspan banner, a decimal column, and a rowspan cell
/// with `VAlign.middle` — the features GFM tables cannot author but the
/// component renders anyway.
private SpanCell[][] showcaseCells()
{
    static SpanCell cell(string s)
        => SpanCell([TextSpan(s)]);

    SpanCell banner = SpanCell([TextSpan("Q3 restock")], colSpan: 3,
        halign: Align.center);
    SpanCell bulk = SpanCell([TextSpan("bulk order")], rowSpan: 2,
        valign: VAlign.middle);
    return [
        [banner],
        [cell("item"), cell("price"), cell("notes")],
        [cell("widget"), cell("12.5"), cell("steady")],
        [cell("gadget"), cell("3.75"), bulk],
        [cell("gizmo"), cell("140")],
    ];
}

/// The same grid in the string view's authoring form.
private Cell[][] showcaseStringCells()
{
    return [
        [Cell("Q3 restock", colSpan: 3, halign: Align.center)],
        [Cell("item"), Cell("price"), Cell("notes")],
        [Cell("widget"), Cell("12.5"), Cell("steady")],
        [Cell("gadget"), Cell("3.75"), Cell("bulk order", rowSpan: 2,
            valign: VAlign.middle)],
        [Cell("gizmo"), Cell("140")],
    ];
}

/// ditto
private TableProps showcaseProps(in TableDemo d)
{
    return TableProps(
        glyphs: presetGlyphs(builtinPresetNames[d.preset % builtinPresetNames.length]),
        headerRows: 2,
        headerCols: d.stubCol ? 1 : 0,
        rowSeparators: d.rowRules,
        columnAligns: [Align.left, Align.decimal, Align.left],
    );
}

/// The framed demo's grid: wide AND tall, so both bars engage.
private SpanCell[][] wideCells()
{
    static SpanCell cell(string s)
        => SpanCell([TextSpan(s)]);

    auto rows = new SpanCell[][](9);
    rows[0] = [cell("id"), cell("description of the entry"),
        cell("first seen"), cell("status")];
    static immutable string[] descs = [
        "a fairly long description sits here",
        "another verbose description of it",
        "a third record with its own story",
        "the fourth entry keeps the pattern",
        "the fifth one closes the set",
        "one more so the clamp really bites",
        "and another for good measure",
        "the last row of the demo",
    ];
    foreach (i, d; descs)
        rows[i + 1] = [cell(text("rec-", i + 1)), cell(d),
            cell(text("2026-0", i % 9 + 1, "-01")),
            cell(i % 2 == 0 ? "active" : "retired")];
    return rows;
}

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const d = s.tableDemo;
    const preset = builtinPresetNames[d.preset % builtinPresetNames.length];

    uint[] body_;
    body_ ~= heading(b, "Table · one grid, two views");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "The span-capable table: an HTML-style slot grid (colspan, rowspan, "
        ~ "sparse placement), header rows and stub columns with heavy rules, "
        ~ "per-column and per-cell alignment including decimal, VAlign, "
        ~ "wrapping under width caps, and pluggable glyph presets. One layout "
        ~ "core decides every width, height and junction; the widget view "
        ~ "below and the string view beside it both materialize its answer.", w);
    body_ ~= spacer(b);

    // The widget view: spans + decimal + VAlign, restyled live.
    auto props = showcaseProps(d);
    auto widgetTable = buildTableWidgets(b, showcaseCells(), props);
    uint[] toggles;
    toggles ~= label(b, text("preset ", preset), Slot.code);
    toggles ~= chip(b, "row rules", d.rowRules);
    toggles ~= chip(b, "stub col", d.stubCol);
    body_ ~= section(b, "widget view — buildTableWidgets", [
        row(b, toggles, 2),
        spacer(b),
        widgetTable.root,
    ]);
    body_ ~= spacer(b);

    // The string view: the SAME cells and props through drawTable, one code
    // line per emitted row — agreement on every junction is the point.
    // (`@trusted`: drawTable predates the explicit-attribute rule, so it
    // defaults to `@system`; nothing in a pure render call is unsafe.)
    uint[] lines;
    const rendered = (() @trusted
        => drawTable(showcaseStringCells(), props))();
    foreach (line; rendered.splitLines)
        lines ~= label(b, line, Slot.code);
    body_ ~= section(b, "string view — drawTable, the same bytes", lines);
    body_ ~= spacer(b);

    // The overflow viewport (TBL7/TBL8): a wide and tall grid behind the
    // framed box — pinned corners and caps, the interior scrolling as one,
    // the bottom border as the h bar and the right border as the v track.
    const availW = boxWidth(w);
    auto framed = buildTableWidgets(b, wideCells(), TableProps(headerRows: 1),
        TableWidgetStyle(), TableViewportSpec(
            availWidth: availW,
            maxLines: 7,
            x: d.scrollX,
            y: d.scrollY));
    uint[] framedRows;
    framedRows ~= label(b, text("content ", framed.width, "×", framed.height,
        "  ·  box ", framed.viewWidth, "×", framed.viewHeight,
        framed.hBar ? "  ·  h bar" : "", framed.vBar ? "  ·  v track" : ""),
        Slot.muted);
    framedRows ~= spacer(b);
    framedRows ~= framed.root;
    body_ ~= section(b, "overflow — the framed viewport", framedRows);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Scroll with [ and ] (columns) and , and . (rows). The frame and the "
        ~ "copy-cutout stay pinned while cells, inner rules and the border "
        ~ "junctions move as one — the same TBL7/TBL8 box hue wraps around a "
        ~ "wide markdown table, where the bars are also mouse targets.", w);

    return column(b, body_);
}

/// The framed demo's box width: obviously narrower than the grid, but never
/// wider than the pane (the catalog's no-horizontal-overflow rule).
private int boxWidth(int contentWidth) pure nothrow @nogc
{
    const inSection = contentWidth - 6; // the section panel's border + padding
    const target = 44;
    if (inSection < 20)
        return inSection > 8 ? inSection : 8;
    return inSection < target ? inSection : target;
}

/// ditto
bool handleKey(ref GalleryState s, in KeyEvent k)
{
    switch (k.ch)
    {
        case 'g':
            s.tableDemo.preset = (s.tableDemo.preset + 1)
                % builtinPresetNames.length;
            return true;
        case 'r': s.tableDemo.rowRules = !s.tableDemo.rowRules; return true;
        case 's': s.tableDemo.stubCol = !s.tableDemo.stubCol; return true;
        // The component clamps to the real overflow; the page only keeps the
        // number in a sane band so it cannot wander far past the edge.
        case '[': s.tableDemo.scrollX = clampScroll(s.tableDemo.scrollX - 4); return true;
        case ']': s.tableDemo.scrollX = clampScroll(s.tableDemo.scrollX + 4); return true;
        case ',': s.tableDemo.scrollY = clampScroll(s.tableDemo.scrollY - 1); return true;
        case '.': s.tableDemo.scrollY = clampScroll(s.tableDemo.scrollY + 1); return true;
        default: return false;
    }
}

private int clampScroll(int n) pure nothrow @nogc
    => n < 0 ? 0 : (n > 80 ? 80 : n);

@("ui_gallery.pages.tableTwoViewsAgreeOnGeometry")
@safe unittest
{
    import sparkles.ui.geometry : cellsOf;

    // The page's whole claim: the widget table and the drawTable output of
    // the same cells + props occupy identical geometry — every emitted line
    // is exactly the widget table's width, under every preset and toggle.
    foreach (presetIdx; 0 .. builtinPresetNames.length)
        foreach (rowRules; [false, true])
            foreach (stub; [false, true])
            {
                TableDemo d = {preset: presetIdx, rowRules: rowRules,
                    stubCol: stub};
                auto props = showcaseProps(d);
                auto b = Builder();
                const res = buildTableWidgets(b, showcaseCells(), props);
                const lines = (() @trusted
                    => drawTable(showcaseStringCells(), props))().splitLines;
                assert(cast(int) lines.length == res.height);
                foreach (line; lines)
                    assert(cast(int) cellsOf(line) == res.width,
                        "the two views disagree on a line's width");
            }
}

@("ui_gallery.pages.tableFramedDemoEngagesBothBars")
@safe unittest
{
    auto b = Builder();
    const res = buildTableWidgets(b, wideCells(), TableProps(headerRows: 1),
        TableWidgetStyle(), TableViewportSpec(availWidth: 44, maxLines: 7));
    assert(res.hBar && res.vBar, "the demo grid must overflow both axes");
    assert(res.viewWidth == 44 && res.viewHeight == 9);
}

@("ui_gallery.pages.tableScrollKeysStayInBand")
@safe unittest
{
    GalleryState s;
    foreach (_; 0 .. 50)
        handleKey(s, KeyEvent(Key.char_, ']'));
    assert(s.tableDemo.scrollX == 80);
    foreach (_; 0 .. 50)
        handleKey(s, KeyEvent(Key.char_, '['));
    assert(s.tableDemo.scrollX == 0);
    handleKey(s, KeyEvent(Key.char_, 'g'));
    assert(s.tableDemo.preset == 1);
}
