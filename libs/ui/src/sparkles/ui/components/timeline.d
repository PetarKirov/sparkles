/**
A timeline (`WGT27`): labelled bars against one time axis, as bootvine draws
the slowest units of a boot.

Each row is the bar's label in one width, so the bars line up, then the bar,
then its length. The bar is a fill span (`GLY8`) across the room the row
leaves, from its start to its end as fractions of the axis, which runs from
zero to `span`; the target draws it as finely as it can — to the pixel in a
window, to an eighth of a cell on a terminal with block elements. The
component names slots and fractions, never glyphs (`GLY1`, D30).
*/
module sparkles.ui.components.timeline;

import core.time : Duration;

import sparkles.ui.canvas : FillAxis;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind;

@safe:

/// One bar of a timeline.
struct TimelineBar
{
    const(char)[] label;   /// borrowed; must outlive the tree
    Duration start;        /// from the axis origin
    Duration end;          /// ditto; at least `start`
    Slot slot = Slot.info; /// the bar's colour role
    /// The length as the caller writes it (one precision for every duration
    /// it shows); empty writes `end - start` with `writeDuration`.
    const(char)[] length;
}

/// The columns a bar's length takes at the end of its row: `999.9ms`.
enum int lengthColumns = 7;

/**
The bar's extent as fractions of an axis from zero to `span`, clamped to
`[0, 1]`. An axis of no length is the bar's own end.
*/
void barFractions(in TimelineBar bar, Duration span, out float from, out float to) pure nothrow @nogc
{
    const axis = span > Duration.zero ? span : bar.end;
    if (axis <= Duration.zero)
        return;
    static float unit(Duration d, Duration axis) pure nothrow @nogc
    {
        const f = cast(float) d.total!"hnsecs" / axis.total!"hnsecs";
        return f < 0 ? 0 : f > 1 ? 1 : f;
    }

    from = unit(bar.start, axis);
    to = unit(bar.end, axis);
}

/**
Adds the bars as a column of rows — label (`labelWidth` columns, cut with
`…` by the display list when longer), bar, length — that takes the width its
parent gives it; returns the column's index.
*/
uint timelineView(ref Builder b, in TimelineBar[] bars, Duration span, int labelWidth)
{
    import std.array : appender;
    import sparkles.base.text.writers : writeDuration;

    uint[] rows;
    foreach (ref bar; bars)
    {
        float from, to;
        barFractions(bar, span, from, to);
        auto length = appender!string;
        if (bar.length.length)
            length.put(bar.length);
        else
            writeDuration(length, bar.end - bar.start);
        const label = b.add(Widget(kind: WidgetKind.text, text: bar.label,
            width: SizeSpec.fixed(labelWidth)));
        const fill = b.add(Widget(kind: WidgetKind.fillSpan, slot: bar.slot,
            width: SizeSpec.grow(), fillFrom: from, fillTo: to, fillAxis: FillAxis.across));
        const len = b.add(Widget(kind: WidgetKind.text, text: length[], slot: Slot.muted,
            width: SizeSpec.fixed(lengthColumns), alignX: Alignment.end));
        rows ~= b.add(Widget(kind: WidgetKind.row, gap: 1, width: SizeSpec.grow(),
            children: [label, fill, len]));
    }
    return b.add(Widget(kind: WidgetKind.column, width: SizeSpec.grow(), children: rows));
}

/// A bar's fractions are its start and end on the axis.
@("ui.timeline.barFractions.onTheAxis")
@safe pure nothrow @nogc unittest
{
    import core.time : msecs, seconds;

    float from, to;
    barFractions(TimelineBar("link", 5.seconds, 7500.msecs), 10.seconds, from, to);
    assert(from == 0.5f && to == 0.75f);
    barFractions(TimelineBar("late", 8.seconds, 12.seconds), 10.seconds, from, to);
    assert(from == 0.8f && to == 1f, "clamped to the axis");
}

/// Each row is its label, a fill span at the bar's fractions in its slot,
/// and its length; laid out, the span takes the room the row leaves.
@("ui.timeline.timelineView.rowsOfFillSpans")
@safe unittest
{
    import core.time : seconds;
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    Builder b;
    const col = timelineView(b, [TimelineBar("compile", 0.seconds, 2.seconds, Slot.success),
        TimelineBar("a-very-long-label", 1.seconds, 4.seconds)], 4.seconds, 6);
    auto tree = b.finish(col);
    const first = tree.nodes[tree.nodes[col].children[0]];
    const span = tree.nodes[first.children[1]];
    assert(span.kind == WidgetKind.fillSpan && span.slot == Slot.success);
    assert(span.fillFrom == 0 && span.fillTo == 0.5f);

    const frames = layout(tree, Constraints(maxW: 40));
    assert(frames[first.children[1]].rect.width == 40 - 6 - 1 - 1 - lengthColumns);
    const ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));
    size_t spans;
    foreach (ref op; ops)
        if (op.kind == OpKind.fillSpan)
            ++spans;
    assert(spans == 2, "one fill span per bar, no glyphs");
}
