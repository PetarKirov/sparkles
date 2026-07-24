/**
The display-list stage of $(MREF sparkles,ui): $(LREF buildDisplayList) walks a
laid-out $(REF WidgetTree, sparkles,ui,widget) and emits a flat
$(REF DrawOp, sparkles,ui,canvas) stream, resolving each node's
$(REF Slot, sparkles,ui,style) to a concrete $(REF Visual, sparkles,ui,style)
against the palette and page colors. This is the last backend-neutral, GL-free
stage — the boundary a painter ($(MREF sparkles,ui,interp,immediate)) or an
SSG/ANSI backend consumes without ever touching a widget or a palette again.
*/
module sparkles.ui.display_list;

import sparkles.ui.canvas : DrawOp, OpKind;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.layout : Frame;
import sparkles.ui.style : Palette, resolveSlot, Slot, Visual;
import sparkles.ui.widget : Widget, WidgetKind, WidgetTree;
import sparkles.base.term_color : RgbColor;

@safe:

/**
Builds the display list for `tree` (already positioned into `frames`), resolving
every slot against `pal` and the page `pageFg`/`pageBg`. Containers paint their
background (when `paintBackground`) before recursing, so children draw on top.
*/
DrawOp[] buildDisplayList(in WidgetTree tree, in Frame[] frames, in Palette pal,
    in RgbColor pageFg, in RgbColor pageBg)
{
    DrawOp[] ops;
    emit(tree, tree.root, frames, pal, pageFg, pageBg, ops);
    return ops;
}

private void emit(in WidgetTree tree, uint idx, in Frame[] frames, in Palette pal,
    in RgbColor pageFg, in RgbColor pageBg, ref DrawOp[] ops)
{
    const node = tree.nodes[idx];
    const rect = frames[idx].rect;
    const vis = resolveSlot(pal, node.slot, pageFg, pageBg);

    // Container/box background first (children paint over it).
    if (node.paintBackground && vis.hasBg)
        ops ~= DrawOp(kind: OpKind.fillRect, rect: rect, slot: node.slot, visual: vis);

    final switch (node.kind) with (WidgetKind)
    {
        case text:
            ops ~= DrawOp(
                kind: OpKind.textRun, rect: rect, text: node.text,
                slot: node.slot, visual: vis,
            );
            break;
        case glyph:
            ops ~= DrawOp(
                kind: OpKind.glyph, rect: rect, glyph: node.glyph,
                slot: node.slot, visual: vis,
            );
            break;
        case line:
            ops ~= DrawOp(
                kind: OpKind.line, rect: rect,
                to: Point(rect.x + node.lineTo.x, rect.y + node.lineTo.y),
                lineStyle: node.lineStyle, slot: node.slot, visual: vis,
            );
            break;
        case box:
            break; // background (if any) already emitted
        case row, column, stack, panel, popup:
            foreach (child; node.children)
                emit(tree, child, frames, pal, pageFg, pageBg, ops);
            break;
    }
}

@("ui.display_list.hoverPopup.surfaceThenText")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    // popup(surface) → column(signature code run, docs run)
    auto b = Builder();
    const sig = b.add(Widget(kind: WidgetKind.text, text: "title: string", slot: Slot.code));
    const docs = b.add(Widget(kind: WidgetKind.text, text: "The title.", slot: Slot.docs));
    const col = b.container(WidgetKind.column, [sig, docs]);
    const popup = b.container(WidgetKind.popup, [col],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true);
    auto tree = b.finish(popup);

    const pal = defaultTwoslashPalette();
    const pageFg = RgbColor(0x22, 0x22, 0x22);
    const pageBg = RgbColor(0xff, 0xff, 0xff);
    auto ops = buildDisplayList(tree, layout(tree), pal, pageFg, pageBg);

    // surface fill, then two text runs (code inherits page fg, docs is muted).
    assert(ops.length == 3);
    assert(ops[0].kind == OpKind.fillRect && ops[0].slot == Slot.surface);
    assert(ops[0].visual.hasBg && ops[0].visual.bg == RgbColor(0xf8, 0xf8, 0xf8));

    assert(ops[1].kind == OpKind.textRun && ops[1].text == "title: string");
    assert(ops[1].visual.fg == pageFg); // code inherits page fg

    assert(ops[2].kind == OpKind.textRun && ops[2].text == "The title.");
    assert(ops[2].visual.fg == RgbColor(0x88, 0x88, 0x88)); // docs muted
}

@("ui.display_list.errorWavyUnderlineAndMessage")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.canvas : LineStyle;
    import sparkles.ui.geometry : Point;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    // A wavy underline spanning 5 cells, then an error-slot message row.
    auto b = Builder();
    const wavy = b.add(Widget(kind: WidgetKind.line, slot: Slot.error,
        lineStyle: LineStyle.wavy, lineTo: Point(5, 0)));
    const msg = b.add(Widget(kind: WidgetKind.text, text: "Type error", slot: Slot.error));
    const col = b.container(WidgetKind.column, [wavy, msg]);
    auto tree = b.finish(col);

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal,
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    assert(ops.length == 2);
    assert(ops[0].kind == OpKind.line && ops[0].lineStyle == LineStyle.wavy);
    assert(ops[0].visual.fg == RgbColor(0xd4, 0x56, 0x56));
    assert(ops[0].to == Point(5, 0)); // origin (0,0) + lineTo (5,0)
    assert(ops[1].kind == OpKind.textRun && ops[1].visual.fg == RgbColor(0xd4, 0x56, 0x56));
}
