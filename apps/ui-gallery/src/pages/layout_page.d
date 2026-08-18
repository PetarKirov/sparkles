/**
The Layout page: the sizing vocabulary, live.

`SizeSpec` is four kinds and two clamps, and reading them is not the same as
seeing three bands redistribute when one becomes `grow`. The knobs are on the
keyboard so the page works identically in a terminal with no mouse.

It also shows the two visibilities apart, which is the distinction that costs
people an afternoon: `hidden` keeps its space and `collapsed` gives it back.
*/
module pages.layout_page;

import std.conv : text;

import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Visibility, Widget, WidgetKind;

import keymap : GalleryCommand;
import kit;
import state : GalleryState, LayoutDemo;

@safe:

/// The bindings the shell prints in the status bar for this page.
// The page's keys are `galleryBindings` rows in `GalleryScope.pageLayout`;
// the status bar and the help panel render them from the table.

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const d = s.layoutDemo;

    uint[] body_;
    body_ ~= heading(b, "Layout · sizing, spacing, alignment");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Four passes, each O(n): natural width up, allocation down, "
        ~ "height-for-width up, placement down. Nothing iterates to a fixed "
        ~ "point — the width/height cycle is broken by ordering.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "the knobs", [
        row(b, [label(b, "width", Slot.muted), chipRow(b,
            ["fit", "grow", "fixed", "percent"], d.widthMode)]),
        row(b, [label(b, "value", Slot.muted),
            label(b, d.fixedCells.text, Slot.code)]),
        row(b, [label(b, "alignX", Slot.muted), chipRow(b,
            ["start", "center", "end"], d.alignX)]),
        row(b, [label(b, "alignY", Slot.muted), chipRow(b,
            ["start", "center", "end"], d.alignY)]),
        row(b, [label(b, "gap", Slot.muted), label(b, d.gap.text, Slot.code),
            label(b, "padding", Slot.muted), label(b, d.padding.text, Slot.code)]),
        row(b, [label(b, "third band", Slot.muted), chipRow(b,
            ["visible", "hidden", "collapsed"], d.third)]),
    ]);
    body_ ~= spacer(b);
    body_ ~= section(b, "the row", [bands(b, d)]);
    body_ ~= spacer(b);

    body_ ~= section(b, "what each width means", [
        kv(b, "fit", "shrink-wrap the content (the default)", 10, Slot.docs),
        kv(b, "grow(n)", "take a weighted share of what is left", 10, Slot.docs),
        kv(b, "fixed(n)", "exactly n cells", 10, Slot.docs),
        kv(b, "percent(n)", "n% of the parent's extent", 10, Slot.docs),
        kv(b, "min / max", "clamps, applied to any of the four", 10, Slot.docs),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "hidden is laid out and not painted; collapsed leaves the flow "
        ~ "entirely. Both also drop out of hit testing, so a bar that is not "
        ~ "drawn cannot be pressed — one assignment governs paint and input, "
        ~ "and a host cannot set the first gate and forget the second.", w);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "There is no margin. Distribution — space-between and friends — is "
        ~ "spelled by inserting grow spacers, which is what the header band at "
        ~ "the top of this window does.", w);

    return column(b, body_);
}

/// Three bands in a row, the first sized by the current knob.
private uint bands(ref Builder b, in LayoutDemo d)
{
    const first = b.add(Widget(
        kind: WidgetKind.panel,
        children: [label(b, "first", Slot.chromeAccent)],
        slot: Slot.chromeFocused,
        width: widthOf(d),
        height: SizeSpec.fixed(3),
        padding: Insets.all(d.padding),
        alignX: d.alignX,
        alignY: d.alignY,
        paintBackground: true,
    ));
    const second = b.add(Widget(
        kind: WidgetKind.panel,
        children: [label(b, "second", Slot.code)],
        slot: Slot.chip,
        height: SizeSpec.fixed(3),
        padding: Insets.all(d.padding),
        alignX: d.alignX,
        alignY: d.alignY,
        paintBackground: true,
    ));
    const third = b.add(Widget(
        kind: WidgetKind.panel,
        children: [label(b, "third", Slot.code)],
        slot: Slot.chip,
        height: SizeSpec.fixed(3),
        padding: Insets.all(d.padding),
        alignX: d.alignX,
        alignY: d.alignY,
        paintBackground: true,
        visibility: d.third,
    ));
    // A trailing `grow` spacer, so the bands stay left-packed when none of them
    // grows — otherwise the row shrink-wraps and there is nothing to see.
    const tail = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));

    return b.add(Widget(
        kind: WidgetKind.row,
        children: [first, second, third, tail],
        gap: d.gap,
        width: SizeSpec.grow(),
    ));
}

/// The `SizeSpec` the current knob names.
SizeSpec widthOf(in LayoutDemo d) pure nothrow @nogc
{
    switch (d.widthMode)
    {
        case 1: return SizeSpec.grow();
        case 2: return SizeSpec.fixed(d.fixedCells);
        case 3: return SizeSpec.percent(d.fixedCells);
        default: return SizeSpec.fit_;
    }
}

/// The page's own key handling, applied by the shell when this page is showing.
/// Returns `true` iff it consumed the key.
bool handleCommand(ref GalleryState s, GalleryCommand cmd, ubyte arg)
{
    switch (cmd)
    {
        case GalleryCommand.layoutWidthMode:
            s.layoutDemo.widthMode = (s.layoutDemo.widthMode + 1) % 4;
            return true;
        case GalleryCommand.layoutAlignX:
            s.layoutDemo.alignX = cycle(s.layoutDemo.alignX);
            return true;
        case GalleryCommand.layoutAlignY:
            s.layoutDemo.alignY = cycle(s.layoutDemo.alignY);
            return true;
        case GalleryCommand.layoutGap:
            s.layoutDemo.gap = (s.layoutDemo.gap + 1) % 4;
            return true;
        case GalleryCommand.layoutPadding:
            s.layoutDemo.padding = (s.layoutDemo.padding + 1) % 3;
            return true;
        case GalleryCommand.layoutThird:
            s.layoutDemo.third = cycleVisibility(s.layoutDemo.third);
            return true;
        case GalleryCommand.layoutGrow:
            s.layoutDemo.fixedCells = clampCells(s.layoutDemo.fixedCells + 2);
            return true;
        case GalleryCommand.layoutShrink:
            s.layoutDemo.fixedCells = clampCells(s.layoutDemo.fixedCells - 2);
            return true;
        default: return false;
    }
}

private Alignment cycle(Alignment a) pure nothrow @nogc
    => cast(Alignment)((a + 1) % 3);

private Visibility cycleVisibility(Visibility v) pure nothrow @nogc
    => cast(Visibility)((v + 1) % 3);

/// Kept in a range where every mode stays legible: a `percent` of 2 is
/// invisible and one of 100 leaves nothing for the other bands.
private int clampCells(int n) pure nothrow @nogc
    => n < 4 ? 4 : (n > 60 ? 60 : n);

@("ui_gallery.pages.layoutWidthKnobSelectsEverySizeSpecKind")
@safe unittest
{
    // Every kind is reachable by pressing `w`, and the cycle returns to where
    // it started — a knob that could not reach `percent` would leave a quarter
    // of the vocabulary undemonstrated.
    LayoutDemo d;
    bool[SizeSpec.Kind.max + 1] seen;
    foreach (_; 0 .. 4)
    {
        seen[widthOf(d).kind] = true;
        d.widthMode = (d.widthMode + 1) % 4;
    }
    static foreach (k; __traits(allMembers, SizeSpec.Kind))
        assert(seen[__traits(getMember, SizeSpec.Kind, k)],
            "the width knob never selects SizeSpec.Kind." ~ k);
    assert(d.widthMode == 0, "the cycle closes");
}

@("ui_gallery.pages.layoutHiddenKeepsItsSpaceAndCollapsedGivesItBack")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;

    // The distinction the page exists to make visible, asserted so the page
    // cannot start claiming something the engine stopped doing.
    int rowWidth(Visibility v)
    {
        LayoutDemo d;
        d.third = v;
        auto b = Builder();
        const first = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(4)));
        const second = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(4),
            visibility: v));
        const r = b.add(Widget(kind: WidgetKind.row, children: [first, second],
            gap: 1));
        auto tree = b.finish(r);
        return layout(tree, Constraints(maxW: 40))[r].rect.width;
    }

    assert(rowWidth(Visibility.visible) == 9);
    assert(rowWidth(Visibility.hidden) == 9, "hidden still occupies its band");
    assert(rowWidth(Visibility.collapsed) == 4, "collapsed leaves the flow");
}

@("ui_gallery.pages.layoutKnobsAreCyclesNotUnboundedCounters")
@safe unittest
{
    // Every knob returns to its starting value, and the size clamp holds at
    // both ends — a page whose knob ran off into a 400-cell band would just
    // look broken.
    GalleryState s;
    foreach (_; 0 .. 3)
        handleCommand(s, GalleryCommand.layoutAlignX, 0);
    assert(s.layoutDemo.alignX == Alignment.start);

    foreach (_; 0 .. 50)
        handleCommand(s, GalleryCommand.layoutGrow, 0);
    assert(s.layoutDemo.fixedCells == 60);
    foreach (_; 0 .. 50)
        handleCommand(s, GalleryCommand.layoutShrink, 0);
    assert(s.layoutDemo.fixedCells == 4);

    assert(!handleCommand(s, GalleryCommand.quit, 0),
        "another scope's command falls through to the shell");
}
