/**
The DSV columns palette (`DSB3`): a modal list of the data columns in the
browser's display order — visibility toggles and move-up/down — over the
grid, in both hosts. This module is the shared VIEW half (the settings
pane's pattern): one widget tree both hosts lay out and paint through
their own canvas; the state (order + visibility) lives on `DsvBrowser`,
and each host carries only the open flag and the cursor.
*/
module dsv_palette;

import std.conv : text;

import dsv_browser : PaletteRow;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind,
    WidgetTree;

/// The palette panel's width in cells: the widest name plus the marker
/// columns, clamped so a pathological header cannot swallow the pane.
uint paletteCols(in PaletteRow[] rows) @safe pure nothrow
{
    size_t widest;
    foreach (r; rows)
        if (r.name.length > widest)
            widest = r.name.length;
    auto cols = widest + 12; // "▸ ✓ " + name + padding + border
    if (cols < 40)
        cols = 40; // the footer hint's width + the frame
    if (cols > 60)
        cols = 60;
    return cast(uint) cols;
}

/**
Builds the palette's widget tree: a framed panel titled `Columns` — one row
per data column (`✓`/`·` visibility, the cursor row on the accent slot) and
a key-hint footer. Returns the finished tree; the host centres and paints.
*/
WidgetTree viewDsvPalette(in PaletteRow[] rows, uint cursor) @safe
{
    Builder b;
    const cols = paletteCols(rows);
    uint[] body_;
    foreach (i, r; rows)
    {
        const cur = i == cursor;
        body_ ~= b.add(Widget(kind: WidgetKind.rich, spans: [
            TextSpan(text: cur ? "▸ " : "  ",
                slot: Slot.chromeAccent),
            TextSpan(text: r.visible ? "✓ " : "· ",
                slot: r.visible ? Slot.info : Slot.muted),
            TextSpan(text: r.name,
                slot: cur ? Slot.chromeAccent
                    : r.visible ? Slot.code : Slot.muted,
                textStyle: TextStyle(bold: cur)),
        ], width: SizeSpec.grow()));
    }
    body_ ~= b.add(Widget(kind: WidgetKind.text,
        text: "␣ show/hide · K/J move · esc close",
        slot: Slot.muted, width: SizeSpec.grow()));

    const content = b.add(Widget(kind: WidgetKind.column, children: body_,
        width: SizeSpec.grow(), clipX: true, clipY: true));
    const boxed = b.add(Widget(kind: WidgetKind.panel,
        children: [content],
        padding: Insets(1, 2, 1, 2),
        slot: Slot.surface, paintBackground: true,
        decoration: Decoration(borderWidth: Insets.all(2),
            borderStyle: BorderStyle.solid, borderRadius: 6,
            borderSlot: Slot.highlightBorder),
        width: SizeSpec.fixed(cols)));
    const titleText = b.add(Widget(kind: WidgetKind.text,
        text: " Columns ", slot: Slot.chromeAccent,
        textStyle: TextStyle(bold: true)));
    const titleRow = b.add(Widget(kind: WidgetKind.row,
        children: [titleText],
        width: SizeSpec.fixed(cols), alignX: Alignment.center));
    const root = b.add(Widget(kind: WidgetKind.stack,
        children: [boxed, titleRow], width: SizeSpec.fixed(cols)));
    return b.finish(root);
}

@("dsv_palette.view.rowsAndCursor")
@safe unittest
{
    const rows = [
        PaletteRow(0, "name", true),
        PaletteRow(2, "price", false),
        PaletteRow(1, "qty", true),
    ];
    auto tree = viewDsvPalette(rows, 1);
    assert(tree.nodes.length > rows.length); // rows + footer + frame
    // The cursor row's marker span and the hidden column's dot render.
    bool sawCursor, sawHidden;
    foreach (ref const w; tree.nodes)
        if (w.kind == WidgetKind.rich)
        {
            foreach (ref const sp; w.spans)
            {
                if (sp.text == "▸ ")
                    sawCursor = true;
                if (sp.text == "· ")
                    sawHidden = true;
            }
        }
    assert(sawCursor && sawHidden);
    assert(paletteCols(rows) >= 40);
}
