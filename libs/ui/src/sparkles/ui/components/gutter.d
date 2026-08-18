/**
Per-line gutter channels: the strips of chrome left of a code column — line
numbers, coverage counts, diff markers, fold arrows, blame — expressed as
$(B layout) rather than as text prefixed into the code.

Which is the whole point. When the chrome lives inside the code row's span
list, every decoration positioned by a $(I source column) — a hover underline,
an error squiggle, a below-line caret — has to be told how far the code was
pushed right, and each producer has to thread that number. Put the chrome in a
sibling cell and the layout engine does it: the code row's frame starts past
the strips, a `stack` child inherits its parent's origin
($(REF place, sparkles,ui,layout)), and a decoration lands on its token with no
offset to pass. `sparkles:syntax` and `sparkles:twoslash` stop knowing about
gutters entirely; they hand their rows to $(LREF withGutter) and are done.

$(B The unit is one source line, not one column per channel.) A column of
per-line cells beside a column of code drifts the moment a line wraps: the
code's third row is the gutter's first. Wrapping each line in its own `row`
keeps them together by construction, and because a `row` top-aligns its
children by default, a one-high strip sits on the first visual row of a wrapped
line with the continuations blank — which is exactly what a line-number gutter
has to do, obtained rather than arranged.

$(B Cells own their text inline.) A `GutterCell` carries a
$(REF SmallBuffer, sparkles,base,smallbuffer) sized so that every realistic
channel fits without touching the heap, so building a document's chrome
allocates nothing however often it reflows.
*/
module sparkles.ui.components.gutter;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

@safe:

/**
How wide a cell's inline storage is, in bytes.

`SmallBuffer`'s union overlays its `T[N]` inline array with the heap slice it
promotes to, so its size is `size_t.sizeof + max(N, (T[]).sizeof)` — on a
64-bit target every `N` up to 16 costs the same 24 bytes, and 16 is therefore
the largest inline capacity available for nothing. It clears every channel
there is: a fold arrow is 3 bytes of UTF-8, a coverage count is bounded at 4 by
`maxCountWidth`, a diff marker is 2, a line number reaches ten million files in
7 digits, a short commit hash is 7 and an ISO date 10. Anything longer — a full
author name — spills to the heap, which is a cost rather than a truncation.
*/
enum gutterCellInline = 16;

/// One channel's cell on one source line, rendered to its channel's width.
struct GutterCell
{
    /// The cell's content, already padded to its channel's width by
    /// $(LREF cellOf) — so a background fills the strip and no alignment
    /// container is needed per cell.
    SmallBuffer!(char, gutterCellInline) text;
    Slot slot = Slot.gutter;
    /// Fill `slot`'s background across the cell (a coverage state band).
    bool paintBackground;
    /// Hover/hit id, `0` for inert chrome. What makes a fold arrow clickable
    /// and a blame cell able to open its commit.
    size_t hitId;
}

/**
A cell holding `content`, padded to `width` cells.

Padding happens here, once, into the cell's own inline storage — not per
layout, and not by wrapping every cell in an alignment container. A gutter of
three channels over a thousand lines is three thousand cells; giving each one a
container to align it would double the arena for a space.

Params:
    content = the text to show, e.g. a formatted line number
    width = the channel's width in cells
    slot = the cell's colour role
    alignEnd = right-align within `width` (the default — numbers line up on
        their last digit); `false` left-aligns, which is what a marker or an
        arrow wants
    paintBackground = fill `slot`'s background across the whole cell
    hitId = hover/hit id, `0` for inert chrome

Returns: the cell, owning its text.
*/
GutterCell cellOf(scope const(char)[] content, int width,
    Slot slot = Slot.gutter, bool alignEnd = true,
    bool paintBackground = false, size_t hitId = 0)
    @safe pure nothrow @nogc
{
    import sparkles.ui.geometry : cellsOf;

    GutterCell cell = {slot: slot, paintBackground: paintBackground, hitId: hitId};
    if (width <= 0)
        return cell;

    // Measured in cells, not bytes: a fold arrow is three bytes of UTF-8 and
    // one column, and padding it by its length would push the code over.
    const shown = cast(int) cellsOf(content);
    const pad = shown >= width ? 0 : width - shown;
    if (alignEnd)
        foreach (_; 0 .. pad)
            cell.text ~= ' ';
    cell.text ~= content;
    if (!alignEnd)
        foreach (_; 0 .. pad)
            cell.text ~= ' ';
    return cell;
}

/// A blank cell `width` cells wide — what a line with nothing to say in this
/// channel shows, and what an interleaved below-line block shows in all of them.
GutterCell blankCell(int width, Slot slot = Slot.gutter)
    @safe pure nothrow @nogc => cellOf(null, width, slot);

/**
One vertical strip of per-line chrome.

A channel is data: the cells and how wide they are. What they $(I mean) —
coverage, blame, line numbers — is the producer's business, which is why this
module can own the layout without knowing about any of them.
*/
struct GutterChannel
{
    /// Stable name. What a toggle addresses, and what a future search scope
    /// names when it offers to look in one channel rather than the content.
    string id;

    /// Off contributes no width and emits no widget — a disabled channel
    /// leaves no strip behind, it does not render an empty one.
    bool enabled = true;

    /// The strip's width in cells. Stable for the document rather than derived
    /// from what is on screen, so toggling one channel never reflows the code
    /// under another.
    int width;

    /// By 0-based source line. A short array is not an error: lines past its
    /// end show blank, which is what a channel that only describes part of a
    /// file does.
    const(GutterCell)[] cells;
}

/// The enabled channels among `channels`.
private auto enabledOf(const(GutterChannel)[] channels)
{
    import std.algorithm.iteration : filter;

    return channels.filter!(c => c.enabled && c.width > 0);
}

/**
The cells the enabled channels occupy before the code starts, including the
one-cell separators between them and before the code.

Nothing in the render path needs this — the layout does the arithmetic. It is
here for the callers that reason about width themselves (a wrap budget, a test).
*/
int gutterWidth(const(GutterChannel)[] channels) @safe pure nothrow @nogc
{
    int total, strips;
    foreach (ch; channels.enabledOf)
    {
        total += ch.width;
        strips++;
    }
    // `strips - 1` gaps between the cells, plus the one before the code: the
    // code never abuts its chrome. So `strips` separators in total.
    return strips == 0 ? 0 : total + strips;
}

/**
The chrome for one source line as a `row` of fixed-width cells.

Params:
    b = the builder to append to
    channels = the document's channels, in left-to-right order
    line = the 0-based source line, or `size_t.max` for a blank strip — what an
        interleaved below-line block passes so it stays aligned with the code
        above it

Returns: the row's index, or `0` when no channel is enabled.
*/
uint gutterRow(ref Builder b, const(GutterChannel)[] channels, size_t line)
{
    uint[] cells;
    foreach (ch; channels.enabledOf)
    {
        const has = line < ch.cells.length;
        // Sliced straight out of the caller's array, never out of a local
        // copy. The storage is *inline*, so a copied cell's `text[]` points
        // into a struct that dies at the end of this iteration — the slice
        // outlives its buffer and the gutter renders whatever the stack held
        // next. Hence also the borrow contract: the channel array must outlive
        // the tree and must not be reallocated under it.
        cells ~= b.add(Widget(
            kind: WidgetKind.text,
            text: has && ch.cells[line].text.length ? ch.cells[line].text[] : null,
            slot: has ? ch.cells[line].slot : Slot.gutter,
            paintBackground: has && ch.cells[line].paintBackground,
            hitId: has ? ch.cells[line].hitId : 0,
            width: SizeSpec.fixed(ch.width),
        ));
    }
    if (cells.length == 0)
        return 0;
    // Fixed *and* floored at its own width. A `fixed` spec is only a base
    // extent: when a row overflows, the engine reclaims the excess from every
    // child in proportion to its slack, which squeezed the chrome to a single
    // cell and left the code hanging off it. Chrome is not negotiable — a long
    // line reflows, the line number does not shrink.
    auto strip = SizeSpec.fixed(gutterWidth(channels) - 1);
    strip.min = strip.value;
    return b.add(Widget(
        kind: WidgetKind.row,
        children: cells,
        width: strip,
        gap: 1,
    ));
}

/**
`content` with its line's chrome beside it.

The one entry point a document producer calls. It never learns the gutter's
width and never offsets anything by it: the code becomes a child of a `row`,
and the layout places it past the strips.

Params:
    b = the builder to append to
    channels = the document's channels, in left-to-right order
    line = the 0-based source line, or `size_t.max` for a blank strip
    content = the row's code widget

Returns: the composed row, or `content` unchanged when no channel is enabled —
    so a document with every channel off is exactly the tree it was before
    gutters existed.
*/
uint withGutter(ref Builder b, const(GutterChannel)[] channels, size_t line,
    uint content)
{
    const strip = gutterRow(b, channels, line);
    if (strip == 0)
        return content;
    return b.add(Widget(
        kind: WidgetKind.row,
        children: [strip, content],
        gap: 1,
    ));
}

@("ui.components.gutter.cellOfPadsToWidthByCells")
@safe unittest
{
    // Right-aligned by default, so numbers line up on their last digit.
    assert(cellOf("12", 4).text[] == "  12");
    assert(cellOf("7", 4, Slot.gutter, alignEnd: false).text[] == "7   ");

    // Padding is measured in cells, not bytes: a fold arrow is three bytes of
    // UTF-8 and one column, and padding by length would push the code over.
    assert(cellOf("▾", 3).text[] == "  ▾");

    // Content at or past the width is left alone rather than truncated — a
    // gutter that lies about a number is worse than one that is a cell wide.
    assert(cellOf("1234", 4).text[] == "1234");
    assert(cellOf("99999", 4).text[] == "99999");

    assert(blankCell(3).text[] == "   ");
    assert(cellOf("x", 0).text.length == 0);
}

@("ui.components.gutter.disabledChannelsLeaveNoStrip")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    const chans = [
        GutterChannel(id: "fold", enabled: false, width: 1),
        GutterChannel(id: "line", enabled: true, width: 3),
        GutterChannel(id: "cov", enabled: false, width: 4),
    ];
    // Only the enabled strip and its separator count — a disabled channel is
    // absent, not blank.
    assert(gutterWidth(chans) == 4);
    assert(gutterWidth([GutterChannel(id: "a", enabled: false, width: 9)]) == 0);
    assert(gutterWidth(null) == 0);

    // Two strips: 3 + 4 cells, a gap between them and one before the code.
    const two = [
        GutterChannel(id: "line", width: 3),
        GutterChannel(id: "cov", width: 4),
    ];
    assert(gutterWidth(two) == 9);

    auto b = Builder();
    const code = b.add(Widget(kind: WidgetKind.text, text: "x();"));
    // Every channel off returns the code untouched, so a document with no
    // gutter is exactly the tree it was before gutters existed.
    assert(withGutter(b, [GutterChannel(id: "a", enabled: false, width: 2)],
        0, code) == code);
    assert(withGutter(b, null, 0, code) == code);
}

@("ui.components.gutter.stripSitsOnTheFirstVisualRowOfAWrappedLine")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Builder, TextSpan;
    import sparkles.ui.wrap : TextWrap;

    // `NUM1`: a wrapped source line is numbered on its first visual row and its
    // continuations are blank. Nothing here arranges that — a `row` top-aligns
    // its children, so a one-high strip beside a three-high code row lands on
    // the first row and the rest of the column is the code's.
    auto cells = [cellOf("12", 2)];
    const chans = [GutterChannel(id: "line", width: 2, cells: cells)];

    auto b = Builder();
    TextSpan[] spans = [TextSpan("aaaa bbbb cccc dddd")];
    const code = b.add(Widget(kind: WidgetKind.rich, spans: spans,
        wrap: TextWrap.greedy));
    auto tree = b.finish(withGutter(b, chans, 0, code));
    auto frames = layout(tree, Constraints(maxW: 12));

    const root = frames[tree.root].rect;
    assert(root.height > 1, "the code wrapped");

    // The strip is one row tall and starts at the document's left edge; the
    // code starts past it and takes the full height.
    uint strip = uint.max, codeIdx = uint.max;
    foreach (i, ref n; tree.nodes)
    {
        if (n.kind == WidgetKind.text && n.text == "12")
            strip = cast(uint) i;
        if (n.kind == WidgetKind.rich)
            codeIdx = cast(uint) i;
    }
    assert(strip != uint.max && codeIdx != uint.max);
    assert(frames[strip].rect.height == 1, "the number is on one row only");
    assert(frames[strip].rect.y == frames[codeIdx].rect.y, "its first row");
    assert(frames[codeIdx].rect.height == root.height, "the code owns the rest");
    // The separator is the row's gap: 2 cells of strip, then one blank.
    assert(frames[codeIdx].rect.x == 3, "the code starts past the chrome");
}

@("ui.components.gutter.blankStripKeepsBelowBlocksAligned")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Builder;

    // An interleaved below-line block (a twoslash error message) is its own row
    // with nothing to say in any channel. It still has to start where the code
    // does, or it hangs left of the text it describes.
    auto cells = [cellOf("12", 2), cellOf("13", 2)];
    const chans = [GutterChannel(id: "line", width: 2, cells: cells)];

    auto b = Builder();
    const code = b.add(Widget(kind: WidgetKind.text, text: "x();"));
    const block = b.add(Widget(kind: WidgetKind.text, text: "^ oops"));
    const doc = b.container(WidgetKind.column, [
        withGutter(b, chans, 0, code),
        withGutter(b, chans, size_t.max, block),
    ]);
    auto tree = b.finish(doc);
    auto frames = layout(tree, Constraints(maxW: 40));

    assert(frames[code].rect.x == frames[block].rect.x,
        "the block lines up with the code, not with the gutter");
}

@("ui.components.gutter.buildingAChannelAllocatesNothing")
@safe pure nothrow @nogc
unittest
{
    // The reason the cell owns a `SmallBuffer` rather than a slice: a document
    // rebuilds its chrome on every reflow, and a per-line allocation there is
    // garbage proportional to lines × channels. `gutterCellInline` is sized so
    // every realistic channel stays inline; this is what keeps a later `.text`
    // call from quietly undoing that.
    auto n = cellOf("1048576", 7);      // a seven-digit line number
    auto c = cellOf("163k", 4);          // a bounded coverage count
    auto m = cellOf("+ ", 2, Slot.gutter, alignEnd: false);
    auto sha = cellOf("a1b2c3d", 7);     // a short commit hash
    auto date = cellOf("2026-08-18", 10); // an ISO date

    assert(n.text[] == "1048576");
    assert(c.text[] == "163k");
    assert(m.text[] == "+ ");
    assert(sha.text[] == "a1b2c3d");
    assert(date.text[] == "2026-08-18");
}

@("ui.components.gutter.cellsRenderTheirOwnTextAcrossLinesAndChannels")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Builder;

    // The failure this guards is silent, which is why it gets its own test: a
    // cell's storage is *inline*, so reading one out of the array by value and
    // slicing the copy yields a pointer into a struct that dies at the end of
    // the iteration. Every cell then renders whatever the stack held next —
    // plausible-looking garbage, no crash.
    auto nums = [cellOf("10", 2), cellOf("11", 2), cellOf("12", 2)];
    auto covs = [cellOf("5", 3), cellOf("0", 3), cellOf("163k", 3)];
    const chans = [
        GutterChannel(id: "line", width: 2, cells: nums),
        GutterChannel(id: "cov", width: 3, cells: covs),
    ];

    auto b = Builder();
    uint[] rows;
    foreach (line; 0 .. 3)
        rows ~= withGutter(b, chans, line,
            b.add(Widget(kind: WidgetKind.text, text: "x();")));
    auto tree = b.finish(b.container(WidgetKind.column, rows));
    cast(void) layout(tree, Constraints(maxW: 40));

    string[] seen;
    foreach (ref n; tree.nodes)
        if (n.kind == WidgetKind.text && n.text.length && n.text != "x();")
            seen ~= n.text.idup;

    assert(seen == ["10", "  5", "11", "  0", "12", "163k"]);
}
