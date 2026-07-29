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
import sparkles.ui.layout : childClipOf, Frame, unclipped;
import sparkles.ui.style : Palette, resolveVisual, Slot, Visual;
import sparkles.ui.widget : Visibility, Widget, WidgetKind, WidgetTree;
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
    emit(tree, tree.root, frames, pal, pageFg, pageBg, unclipped(), ops);
    return ops;
}

private void emit(in WidgetTree tree, uint idx, in Frame[] frames, in Palette pal,
    in RgbColor pageFg, in RgbColor pageBg, in Rect clip, ref DrawOp[] ops)
{
    const node = tree.nodes[idx];
    const rect = frames[idx].rect;

    // `hidden` occupies its frame but paints nothing; `collapsed` was already
    // removed from flow by layout (LAY11). Either way the subtree emits no ops.
    if (node.visibility != Visibility.visible)
        return;

    // Cull a subtree that lies fully outside the effective clip (scrolled off
    // a viewport). Zero-sized frames are kept — a border-only box measures 0×0.
    if (!rect.empty && rect.intersection(clip).empty)
        return;
    Visual vis = resolveVisual(pal, node.slot, node.decoration, node.textStyle, pageFg, pageBg);

    // The background fill is gated by `paintBackground`; a border/shadow/arrow rides
    // the decoration independently (a box can have a border but no fill — the
    // `.twoslash-hover` dotted underline). Mask `hasBg` so the op means exactly
    // "fill this bg", then emit the decorated box first (children paint over it).
    vis.hasBg = node.paintBackground && vis.hasBg;
    if (vis.hasBg || vis.border.any || vis.shadow.any || vis.arrow)
        ops ~= DrawOp(kind: OpKind.fillRect, rect: rect, slot: node.slot, visual: vis);

    final switch (node.kind) with (WidgetKind)
    {
        case text:
            const lines = frames[idx].lines;
            if (lines.length == 0)
            {
                ops ~= DrawOp(
                    kind: OpKind.textRun, rect: rect, text: node.text,
                    slot: node.slot, visual: vis,
                );
                break;
            }
            // A wrapped run: one op per broken line, stacked down the frame.
            // Each op keeps the node's allocated content width (the painters
            // take their advance from the text itself).
            const inner = rect.deflate(node.padding);
            foreach (li, ln; lines)
                ops ~= DrawOp(
                    kind: OpKind.textRun,
                    rect: Rect(inner.x, inner.y + cast(int) li, inner.width, 1),
                    text: ln, slot: node.slot, visual: vis,
                );
            break;
        case rich:
            // One op per styled span, advancing along the row (one row per
            // wrapped line); each span resolves its own slot/chrome against
            // the node's as fallback, and a `paintBackground` span (an inline
            // pill) fills its cells first.
            import sparkles.ui.geometry : cellsOf;
            import sparkles.ui.style : TextStyle;
            import sparkles.ui.widget : TextSpan;

            const inner = rect.deflate(node.padding);

            void emitSpanRow(scope const TextSpan[] spans, int y)
            {
                int x = inner.x;
                foreach (ref span; spans)
                {
                    const slot = span.slot == Slot.inherit ? node.slot : span.slot;
                    const style = span.textStyle == TextStyle.init
                        ? node.textStyle : span.textStyle;
                    const w = cast(int) cellsOf(span.text);
                    auto vis = resolveVisual(pal, slot, node.decoration, style,
                        pageFg, pageBg);
                    vis.hasBg = span.paintBackground && vis.hasBg;
                    const r = Rect(x, y, w, 1);
                    if (vis.hasBg)
                        ops ~= DrawOp(kind: OpKind.fillRect, rect: r,
                            slot: slot, visual: vis);
                    ops ~= DrawOp(kind: OpKind.textRun, rect: r,
                        text: span.text, slot: slot, visual: vis);
                    x += w;
                }
            }

            if (frames[idx].spanLines.length)
                foreach (li, line; frames[idx].spanLines)
                    emitSpanRow(line, inner.y + cast(int) li);
            else
                emitSpanRow(node.spans, inner.y);
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
            // A clipping container brackets its children in scissor ops. The
            // pushed rect is the *effective* clip — this node's padded content
            // box on each clipped axis, already intersected with the ancestor
            // clip — so a canvas replaces rather than intersects.
            const clips = node.clipX || node.clipY;
            const childClip = childClipOf(node, rect, clip);
            if (clips)
                ops ~= DrawOp(kind: OpKind.pushClip, rect: childClip);
            foreach (child; node.children)
                emit(tree, child, frames, pal, pageFg, pageBg, childClip, ops);
            if (clips)
                ops ~= DrawOp(kind: OpKind.popClip);
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

@("ui.display_list.decoratedBoxAndStyledText")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : BorderStyle, Decoration, defaultTwoslashPalette,
        FontRole, TextStyle;
    import sparkles.base.term_style : TextAttr;

    // A popup surface (fill + 1px solid border + radius 4 + shadow) over a docs run
    // (sans face, 0.8em, italic).
    auto b = Builder();
    const docs = b.add(Widget(kind: WidgetKind.text, text: "The title.", slot: Slot.docs,
        textStyle: TextStyle(fontRole: FontRole.docs, fontScale: 80, italic: true)));
    const popup = b.container(WidgetKind.popup, [docs],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true,
        decoration: Decoration(borderWidth: Insets.all(1), borderStyle: BorderStyle.solid,
            borderRadius: 4, shadow: true));
    auto tree = b.finish(popup);

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal,
        RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff));

    // The box op carries fill + border + radius + shadow in one resolved Visual.
    assert(ops[0].kind == OpKind.fillRect && ops[0].visual.hasBg);
    assert(ops[0].visual.border.any && ops[0].visual.border.style == BorderStyle.solid);
    assert(ops[0].visual.borderRadius == 4 && ops[0].visual.shadow.any);

    // The text op carries the resolved font role/scale + the packed italic bit.
    const t = ops[$ - 1];
    assert(t.kind == OpKind.textRun && t.text == "The title.");
    assert(t.visual.fontRole == FontRole.docs && t.visual.fontScale == 80);
    assert((t.visual.styleBits & TextAttr.italic.bits) != 0);
}

@("ui.display_list.wrappedTextEmitsOneRunPerLine")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui.wrap : TextWrap;

    auto b = Builder();
    Widget para = Widget(kind: WidgetKind.text,
        text: "the quick brown fox", slot: Slot.docs, wrap: TextWrap.greedy);
    const t = b.add(para);
    const col = b.container(WidgetKind.column, [t]);
    auto tree = b.finish(col);

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree, Constraints(maxW: 10)), pal,
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    // One run per broken line, stacked one row apart, same resolved visual.
    assert(ops.length == 2);
    assert(ops[0].kind == OpKind.textRun && ops[0].text == "the quick");
    assert(ops[1].kind == OpKind.textRun && ops[1].text == "brown fox");
    assert(ops[0].rect.y == 0 && ops[1].rect.y == 1);
    assert(ops[0].visual == ops[1].visual);
}

@("ui.display_list.viewportClipsScrollsAndCulls")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.geometry : SizeSpec;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    // A 2-row viewport over 5 rows, scrolled down by one: rows 1..2 visible,
    // rows 0/3/4 culled, and the children bracketed in scissor ops.
    auto b = Builder();
    uint[] rows;
    foreach (t; ["zero", "one", "two", "three", "four"])
        rows ~= b.add(Widget(kind: WidgetKind.text, text: t));
    Widget viewW = Widget(kind: WidgetKind.column, children: rows,
        height: SizeSpec.fixed(2), clipY: true, childOffset: Point(0, 1));
    const view = b.add(viewW);
    auto tree = b.finish(view);

    const pal = defaultTwoslashPalette();
    auto frames = layout(tree);
    assert(frames[rows[0]].rect.y == -1); // scrolled above the viewport
    assert(frames[rows[1]].rect.y == 0);

    auto ops = buildDisplayList(tree, frames, pal,
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    // pushClip, the two visible rows, popClip — nothing else.
    assert(ops.length == 4);
    assert(ops[0].kind == OpKind.pushClip);
    // Only y is clipped: the rect covers rows 0..2 and stays unbounded on x.
    assert(ops[0].rect.y == 0 && ops[0].rect.height == 2);
    assert(ops[0].rect.x < -1_000_000 && ops[0].rect.width > 1_000_000);
    assert(ops[1].kind == OpKind.textRun && ops[1].text == "one");
    assert(ops[2].kind == OpKind.textRun && ops[2].text == "two");
    assert(ops[3].kind == OpKind.popClip);
}

@("ui.display_list.richTextEmitsOneRunPerSpan")
@safe unittest
{
    import sparkles.ui.widget : Builder, TextSpan;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    // A syntax-highlighted signature as ONE node of styled spans — no backend
    // overpaint, no per-token widget row.
    auto b = Builder();
    Widget sig = Widget(kind: WidgetKind.rich, slot: Slot.code, spans: [
        TextSpan("const", Slot.error),  // stand-in slots with distinct colors
        TextSpan(" title: "),           // inherits the node slot (code)
        TextSpan("string", Slot.docs),
    ]);
    const t = b.add(sig);
    auto tree = b.finish(t);

    const pal = defaultTwoslashPalette();
    auto frames = layout(tree);
    assert(frames[t].rect.width == 5 + 8 + 6); // spans measured end to end

    auto ops = buildDisplayList(tree, frames, pal,
        RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff));
    assert(ops.length == 3);
    assert(ops[0].text == "const" && ops[0].rect.x == 0 && ops[0].rect.width == 5);
    assert(ops[1].text == " title: " && ops[1].rect.x == 5);
    assert(ops[2].text == "string" && ops[2].rect.x == 13);
    assert(ops[0].visual.fg != ops[1].visual.fg);      // spans carry their slots
    assert(ops[1].slot == Slot.code);                  // inherit → the node slot
}

@("ui.display_list.borderOnlyBoxStillEmits")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : BorderStyle, Decoration, defaultTwoslashPalette;

    // The `.twoslash-hover` token: a bottom-only dotted border, no background fill,
    // `paintBackground` false — the decorated box op must still be emitted.
    auto b = Builder();
    const tok = b.add(Widget(kind: WidgetKind.box, slot: Slot.code,
        decoration: Decoration(borderWidth: Insets(0, 0, 1, 0),
            borderStyle: BorderStyle.dotted, borderSlot: Slot.code)));
    auto tree = b.finish(tok);

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal,
        RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff));

    assert(ops.length == 1 && ops[0].kind == OpKind.fillRect);
    assert(!ops[0].visual.hasBg); // border-only, no fill
    assert(ops[0].visual.border.any && ops[0].visual.border.style == BorderStyle.dotted);
    assert(ops[0].visual.border.width == Insets(0, 0, 1, 0));
}
