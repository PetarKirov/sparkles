/**
The small view vocabulary every page is written in.

Deliberately thin: these are $(B compositions) of `sparkles.ui.widget`, not new
widget kinds, and none of them holds state. A page that needs something these do
not offer builds it from `Widget` directly rather than growing a helper nobody
else uses — the catalog's job is to show the toolkit, not to accumulate a
private one.
*/
module kit;

import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind;
import sparkles.ui.wrap : TextWrap;

@safe:

/// A page's title line: accented and bold, with a full-width rule under it.
uint heading(ref Builder b, string title)
{
    const caption = b.add(Widget(
        kind: WidgetKind.text,
        text: title,
        slot: Slot.chromeAccent,
        textStyle: TextStyle(bold: true),
    ));
    const rule = b.add(Widget(
        kind: WidgetKind.box,
        slot: Slot.border,
        width: SizeSpec.grow(),
        height: SizeSpec.fixed(1),
        paintBackground: true,
        stretch: true,
    ));
    return b.add(Widget(
        kind: WidgetKind.column,
        children: [caption, rule],
        width: SizeSpec.grow(),
    ));
}

/// A sub-heading inside a page.
uint subheading(ref Builder b, string title)
    => b.add(Widget(
        kind: WidgetKind.text,
        text: title,
        slot: Slot.info,
        textStyle: TextStyle(bold: true),
    ));

/// Prose, wrapped at `width`. `hangIndent` indents continuation lines, which is
/// what a bulleted line wants so its text aligns under itself and not under the
/// bullet.
uint para(ref Builder b, const(char)[] text, int width, int hangIndent = 0)
    => b.add(Widget(
        kind: WidgetKind.text,
        text: text,
        slot: Slot.docs,
        width: SizeSpec.fixed(width),
        wrap: TextWrap.greedy,
        hangIndent: hangIndent,
    ));

/// One run of text in a named slot — the primitive most pages spend their time
/// on, so it is worth not spelling out every time.
uint label(ref Builder b, const(char)[] text, Slot slot = Slot.inherit,
    TextStyle style = TextStyle.init)
    => b.add(Widget(kind: WidgetKind.text, text: text, slot: slot,
        textStyle: style));

/// A `name  value` row: muted name in a fixed column, value in `slot`.
uint kv(ref Builder b, string name, const(char)[] value, int nameWidth = 18,
    Slot slot = Slot.code)
{
    const k = b.add(Widget(
        kind: WidgetKind.text,
        text: name,
        slot: Slot.muted,
        width: SizeSpec.fixed(nameWidth),
    ));
    const v = b.add(Widget(kind: WidgetKind.text, text: value, slot: slot));
    return b.add(Widget(kind: WidgetKind.row, children: [k, v], gap: 1));
}

/// A bordered panel with a title, holding `children` in a column.
uint section(ref Builder b, string title, uint[] children, int gap = 0)
{
    const caption = b.add(Widget(
        kind: WidgetKind.text,
        text: title,
        slot: Slot.chromeAccent,
        textStyle: TextStyle(bold: true),
    ));
    const inner = b.add(Widget(
        kind: WidgetKind.column,
        children: children,
        gap: gap,
        width: SizeSpec.grow(),
    ));
    // The rows go in an explicit `column`. A `panel` is a stack — its children
    // share the origin — so handing it the caption and the body directly draws
    // one on top of the other, which is exactly what it did the first time.
    const stackedRows = b.add(Widget(
        kind: WidgetKind.column,
        children: [caption, inner],
        width: SizeSpec.grow(),
    ));
    return b.add(Widget(
        kind: WidgetKind.panel,
        children: [stackedRows],
        slot: Slot.surface,
        // Vertical padding of one, because the border is drawn on the panel's
        // own perimeter cells: without it the caption lands on the top rule.
        padding: Insets.symmetric(1, 2),
        width: SizeSpec.grow(),
        decoration: Decoration(
            borderWidth: Insets.all(1),
            borderStyle: BorderStyle.solid,
            borderSlot: Slot.border,
        ),
    ));
}

/// `n` blank rows — vertical breathing room without a `gap` on the parent,
/// which would space *every* child.
uint spacer(ref Builder b, int rows = 1)
    => b.add(Widget(kind: WidgetKind.box, height: SizeSpec.fixed(rows)));

/// A full-width horizontal rule.
uint hrule(ref Builder b)
    => b.add(Widget(
        kind: WidgetKind.box,
        slot: Slot.border,
        width: SizeSpec.grow(),
        height: SizeSpec.fixed(1),
        paintBackground: true,
        stretch: true,
    ));

/// A small pill: lit when `on`, muted otherwise. The catalog's on/off indicator.
uint chip(ref Builder b, const(char)[] text, bool on)
{
    const caption = b.add(Widget(
        kind: WidgetKind.text,
        text: text,
        slot: on ? Slot.chromeAccent : Slot.muted,
        textStyle: TextStyle(bold: on),
    ));
    return b.add(Widget(
        kind: WidgetKind.panel,
        children: [caption],
        slot: on ? Slot.chromeFocused : Slot.chip,
        padding: Insets.symmetric(0, 1),
        paintBackground: true,
    ));
}

/// A row of `chip`s, one lit.
uint chipRow(ref Builder b, scope const(string)[] labels, size_t active)
{
    auto chips = new uint[](labels.length);
    foreach (i, l; labels)
        chips[i] = chip(b, l, i == active);
    return b.add(Widget(kind: WidgetKind.row, children: chips, gap: 1));
}

/// A column of `children`, the shape a page's body almost always is.
uint column(ref Builder b, uint[] children, int gap = 0)
    => b.add(Widget(
        kind: WidgetKind.column,
        children: children,
        gap: gap,
        width: SizeSpec.grow(),
    ));

/// A row of `children`.
uint row(ref Builder b, uint[] children, int gap = 1)
    => b.add(Widget(kind: WidgetKind.row, children: children, gap: gap));

/// A key-binding hint: the key in accent, its meaning muted.
uint keyHint(ref Builder b, string key, string meaning)
{
    const k = b.add(Widget(
        kind: WidgetKind.text,
        text: key,
        slot: Slot.chromeAccent,
        textStyle: TextStyle(bold: true),
    ));
    const m = b.add(Widget(kind: WidgetKind.text, text: meaning, slot: Slot.muted));
    return b.add(Widget(kind: WidgetKind.row, children: [k, m], gap: 1));
}

/// A specimen: a fixed-width caption naming what is being shown, and the thing
/// itself beside it. Every catalog page is a column of these.
uint specimen(ref Builder b, string caption, uint subject, int captionWidth = 16)
{
    const name = b.add(Widget(
        kind: WidgetKind.text,
        text: caption,
        slot: Slot.muted,
        width: SizeSpec.fixed(captionWidth),
    ));
    return b.add(Widget(
        kind: WidgetKind.row,
        children: [name, subject],
        gap: 1,
        alignY: Alignment.start,
    ));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui_gallery.kit.specimenAlignsCaptionsInAColumn")
@safe unittest
{
    import sparkles.ui.layout : layout;

    // Every specimen's subject starts at the same column whatever its caption
    // is, which is the only reason a page of them reads as a table.
    auto b = Builder();
    const one = specimen(b, "row", label(b, "a"));
    const two = specimen(b, "much longer name", label(b, "b"));
    auto tree = b.finish(column(b, [one, two]));
    auto frames = layout(tree);

    const a = frames[tree.nodes[one].children[1]].rect.x;
    const c = frames[tree.nodes[two].children[1]].rect.x;
    assert(a == c, "specimen subjects must share a column");
}

@("ui_gallery.kit.chipRowLightsExactlyOne")
@safe unittest
{
    auto b = Builder();
    const r = chipRow(b, ["fit", "grow", "fixed"], 1);
    auto tree = b.finish(r);

    size_t lit;
    foreach (c; tree.nodes[r].children)
        if (tree.nodes[c].slot == Slot.chromeFocused)
            ++lit;
    assert(lit == 1, "exactly one chip is active");
}

@("ui_gallery.kit.headingRuleSpansTheWidth")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;

    auto b = Builder();
    const h = heading(b, "Primitives");
    auto tree = b.finish(h);
    auto frames = layout(tree, Constraints(maxW: 40));

    const rule = tree.nodes[h].children[1];
    assert(frames[rule].rect.width == 40, "the rule spans the pane");
}
