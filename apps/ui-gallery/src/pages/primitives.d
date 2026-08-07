/**
The Primitives page: one labelled specimen per `WidgetKind`.

Ten kinds, and the two that surprise people are the containers that are $(B not)
flows: `stack`, `panel` and `popup` give every child the same origin, so a panel
handed a caption and a body draws one on top of the other. The page shows that
outright rather than leaving it to be discovered — the first version of this
gallery's own `section` helper got it wrong.
*/
module pages.primitives;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.canvas : LineStyle;
import sparkles.ui.geometry : Insets, Point, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind;
import sparkles.ui.wrap : TextWrap;

import kit;
import state : GalleryState;

@safe:

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;

    uint[] leaves;
    leaves ~= specimen(b, "box", b.add(Widget(
        kind: WidgetKind.box,
        slot: Slot.chromeAccent,
        width: SizeSpec.fixed(12),
        height: SizeSpec.fixed(1),
        paintBackground: true,
    )));
    leaves ~= specimen(b, "text", label(b, "a run of text", Slot.code));
    leaves ~= specimen(b, "rich", richSpecimen(b));
    leaves ~= specimen(b, "glyph", b.add(Widget(
        kind: WidgetKind.glyph, glyph: '◆', slot: Slot.info)));
    // A line over a run rather than alone: on the cell grid a `line` becomes
    // the cells' underline attribute, so one drawn over blanks is invisible.
    // Over text it is what it is actually for — the twoslash error squiggle.
    leaves ~= specimen(b, "line · solid", underlined(b, "an underlined run",
        Slot.border, LineStyle.solid));
    leaves ~= specimen(b, "line · wavy", underlined(b, "a squiggled run",
        Slot.error, LineStyle.wavy));

    uint[] flows;
    flows ~= specimen(b, "row", b.add(Widget(
        kind: WidgetKind.row,
        children: [tile(b, "one"), tile(b, "two"), tile(b, "three")],
        gap: 1,
    )));
    flows ~= specimen(b, "column", b.add(Widget(
        kind: WidgetKind.column,
        children: [tile(b, "one"), tile(b, "two")],
    )));

    uint[] overlays;
    overlays ~= specimen(b, "stack", b.add(Widget(
        kind: WidgetKind.stack,
        children: [
            b.add(Widget(
                kind: WidgetKind.box,
                slot: Slot.highlight,
                width: SizeSpec.fixed(20),
                height: SizeSpec.fixed(1),
                paintBackground: true,
            )),
            label(b, "  over the fill", Slot.code),
        ],
    )));
    overlays ~= specimen(b, "panel", b.add(Widget(
        kind: WidgetKind.panel,
        children: [b.add(Widget(
            kind: WidgetKind.column,
            children: [label(b, "padded,", Slot.code), label(b, "bordered", Slot.code)],
        ))],
        slot: Slot.surface,
        padding: Insets.symmetric(1, 2),
        decoration: Decoration(
            borderWidth: Insets.all(1),
            borderStyle: BorderStyle.solid,
            borderSlot: Slot.border,
        ),
    )));
    overlays ~= specimen(b, "popup", b.add(Widget(
        kind: WidgetKind.popup,
        children: [b.add(Widget(
            kind: WidgetKind.column,
            children: [label(b, "floats, with", Slot.code), label(b, "a shadow", Slot.docs)],
        ))],
        slot: Slot.surface,
        padding: Insets.symmetric(1, 2),
        paintBackground: true,
        decoration: Decoration(
            borderWidth: Insets.all(1),
            borderStyle: BorderStyle.solid,
            borderSlot: Slot.border,
            borderRadius: 4,
            shadow: true,
        ),
    )));

    uint[] body_;
    body_ ~= heading(b, "Primitives · the ten widget kinds");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Every tree in this catalog is built from these and nothing else. A "
        ~ "widget names a semantic slot, never a colour — the palette resolves "
        ~ "it while the display list is built, which is why every specimen "
        ~ "below repaints when you press ] .", w);
    body_ ~= spacer(b);
    body_ ~= section(b, "leaves", leaves);
    body_ ~= spacer(b);
    body_ ~= section(b, "flow containers", flows);
    body_ ~= spacer(b);
    body_ ~= section(b, "overlay containers", overlays);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "stack, panel and popup are NOT flows: every child shares the "
        ~ "container's origin and z-order is child order. A panel handed a "
        ~ "caption and a body draws them on top of each other — put an "
        ~ "explicit column inside it.", w, hangIndent: 2);

    return column(b, body_);
}

/// A text run with a `line` stroked across it, in a `stack`.
private uint underlined(ref Builder b, string text, Slot slot, LineStyle style)
{
    const run = label(b, text, Slot.code);
    const stroke = b.add(Widget(
        kind: WidgetKind.line,
        slot: slot,
        lineTo: Point(cast(int) text.length, 0),
        lineStyle: style,
        width: SizeSpec.fixed(cast(int) text.length),
        height: SizeSpec.fixed(1),
    ));
    return b.add(Widget(kind: WidgetKind.stack, children: [run, stroke]));
}

/// A `rich` run: one text node, several styled spans, wrapped as a unit.
private uint richSpecimen(ref Builder b)
{
    auto spans = [
        TextSpan(text: "auto ", slot: Slot.info),
        TextSpan(text: "n", slot: Slot.code, textStyle: TextStyle(bold: true)),
        TextSpan(text: " = ", slot: Slot.muted),
        // A resolved colour, bypassing the slot vocabulary: this is the channel
        // a syntax highlighter uses, since its rules resolve outside the
        // semantic palette entirely (`THM1`).
        TextSpan(text: "42", hasFg: true, fg: RgbColor(0xe5, 0xc0, 0x7b)),
        TextSpan(text: ";", slot: Slot.muted),
    ];
    return b.add(Widget(
        kind: WidgetKind.rich,
        spans: spans,
        wrap: TextWrap.greedy,
        width: SizeSpec.fixed(20),
    ));
}

private uint tile(ref Builder b, string text)
    => b.add(Widget(
        kind: WidgetKind.panel,
        children: [label(b, text, Slot.chromeAccent)],
        slot: Slot.chip,
        padding: Insets.symmetric(0, 1),
        paintBackground: true,
    ));

@("ui_gallery.pages.primitivesCoversEveryWidgetKind")
@safe unittest
{
    // The page's contract: if a kind exists, it has a specimen. A kind added to
    // the toolkit and not to the catalog is exactly the drift this prevents.
    auto b = Builder();
    auto tree = b.finish(view(b, GalleryState.init));

    bool[WidgetKind.max + 1] seen;
    foreach (ref n; tree.nodes)
        seen[n.kind] = true;

    static foreach (k; __traits(allMembers, WidgetKind))
        assert(seen[__traits(getMember, WidgetKind, k)],
            "no specimen for WidgetKind." ~ k);
}

@("ui_gallery.pages.primitivesStackChildrenShareAnOrigin")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;

    // The claim the page makes in prose, asserted. If `stack` ever became a
    // flow the page would be telling readers something false.
    auto b = Builder();
    const fill = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(8),
        height: SizeSpec.fixed(1)));
    const over = label(b, "x");
    const st = b.add(Widget(kind: WidgetKind.stack, children: [fill, over]));
    auto tree = b.finish(st);
    auto frames = layout(tree, Constraints(maxW: 40));

    assert(frames[fill].rect.origin == frames[over].rect.origin);
}
