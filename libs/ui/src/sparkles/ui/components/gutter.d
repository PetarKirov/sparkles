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

    /// What survives a squeeze. When the enabled channels do not fit their
    /// budget, $(LREF withinBudget) turns off the lowest-priority ones until
    /// they do — so this is $(I not) the icon slot's $(LREF foldPriority),
    /// which decides who owns a cell. One ranks providers inside a strip; this
    /// ranks strips against the pane.
    int priority;

    /// By 0-based source line. A short array is not an error: lines past its
    /// end show blank, which is what a channel that only describes part of a
    /// file does.
    const(GutterCell)[] cells;
}

/**
`channels` with its lowest-priority strips switched off until the rest fit
`budget` cells.

$(B Whole strips, never partial ones.) A gutter has no natural stopping width:
line numbers, a fold arrow and a coverage count already come to nine cells
before anything interesting arrives, and a blame lane — a short hash, a date, an
author — roughly doubles that on its own. On an eighty-column pane that is a
quarter of the reader's text gone to chrome, and on a split pane it is most of
it.

The lever is which strips render, not how wide they are. A channel narrowed
below its content lies: a line number cut to two digits reads as a different
line, a truncated hash resolves to a different commit, and both look exactly
like the truth. So a channel that does not fit is turned off, which is legible —
the reader sees that the column is gone, and toggling something else back brings
it in.

Ties drop the rightmost first, so the strips nearest the code go before the ones
framing the pane and the ordering is deterministic rather than incidental.

Params:
    channels = the reserved channels, mutated in place and returned
    budget = the cells the gutter may occupy, separators included
    separator = the cells between adjacent strips and before the code

Returns: `channels`, for chaining onto a builder call.
*/
GutterChannel[] withinBudget(return GutterChannel[] channels, int budget,
    int separator = 1) @safe pure nothrow @nogc
{
    while (gutterWidth(channels, separator) > budget)
    {
        // The lowest-priority enabled strip, last one winning a tie.
        size_t victim = size_t.max;
        int worst;
        foreach (i, ref ch; channels)
        {
            if (!ch.enabled || ch.width <= 0)
                continue;
            if (victim == size_t.max || ch.priority <= worst)
            {
                victim = i;
                worst = ch.priority;
            }
        }
        if (victim == size_t.max)
            break;      // nothing left to drop; the budget was under one strip
        channels[victim].enabled = false;
    }
    return channels;
}

@("ui.components.gutter.withinBudgetDropsWholeStripsLowestFirst")
@safe pure nothrow @nogc
unittest
{
    static GutterChannel[3] make()
    {
        return [
            GutterChannel(id: "icons", width: 1, priority: 20),
            GutterChannel(id: "line", width: 3, priority: 30),
            GutterChannel(id: "cov", width: 4, priority: 10),
        ];
    }

    // 1 + 3 + 4 + two separators + one before the code == 11.
    auto full = make();
    assert(gutterWidth(full[]) == 11);
    assert(gutterWidth(withinBudget(full[], 11)) == 11, "a fit changes nothing");

    // One cell short, and coverage is the cheapest thing to lose.
    auto tight = make();
    withinBudget(tight[], 10);
    assert(!tight[2].enabled && tight[0].enabled && tight[1].enabled);
    assert(gutterWidth(tight[]) == 6);

    // Squeezed to nothing but the reader's coordinate system.
    auto narrow = make();
    withinBudget(narrow[], 4);
    assert(narrow[1].enabled && !narrow[0].enabled && !narrow[2].enabled);

    // A budget under even one strip leaves no gutter rather than a clipped one
    // — the loop terminates instead of spinning on an empty list.
    auto none = make();
    withinBudget(none[], 0);
    assert(gutterWidth(none[]) == 0);
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
int gutterWidth(const(GutterChannel)[] channels, int separator = 1)
    @safe pure nothrow @nogc
{
    int total, strips;
    foreach (ch; channels.enabledOf)
    {
        total += ch.width;
        strips++;
    }
    // One cell between adjacent strips, plus `separator` before the code.
    return strips == 0 ? 0 : total + (strips - 1) + separator;
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
        cells ~= cellWidget(b, ch, line < ch.cells.length ? &ch.cells[line] : null);
    return stripOf(b, channels, cells);
}

/**
As $(LREF gutterRow), but with the row's cells given directly rather than
looked up by source line.

For a producer whose rows are not one per source line. A diff row shows an old
line, a new line, both or neither, and its position in the file is not an index
into anything — so it computes its own cells and passes them, one per enabled
channel in order. A short array leaves the remaining strips blank.

Params:
    b = the builder to append to
    channels = the document's channels, in left-to-right order
    cells = this row's cells, parallel to the $(I enabled) channels

Returns: the row's index, or `0` when no channel is enabled.
*/
uint gutterRowOf(ref Builder b, const(GutterChannel)[] channels,
    const(GutterCell)[] cells)
{
    uint[] widgets;
    size_t i;
    foreach (ch; channels.enabledOf)
    {
        widgets ~= cellWidget(b, ch, i < cells.length ? &cells[i] : null);
        i++;
    }
    return stripOf(b, channels, widgets);
}

/// One channel's cell widget. `cell` is a $(I pointer) into the caller's
/// storage, never a copy: a cell's text lives inline, so slicing a copy yields
/// a dangling pointer the moment it goes out of scope — the gutter then renders
/// whatever the stack held next, which looks like text and is not.
private uint cellWidget(ref Builder b, in GutterChannel ch, const(GutterCell)* cell)
{
    return b.add(Widget(
        kind: WidgetKind.text,
        text: cell !is null && cell.text.length ? cell.text[] : null,
        slot: cell !is null ? cell.slot : Slot.gutter,
        paintBackground: cell !is null && cell.paintBackground,
        hitId: cell !is null ? cell.hitId : 0,
        width: SizeSpec.fixed(ch.width),
    ));
}

/// The strip row holding `cells`, floored at its own width.
private uint stripOf(ref Builder b, const(GutterChannel)[] channels, uint[] cells)
{
    if (cells.length == 0)
        return 0;
    // Fixed *and* floored. A `fixed` spec is only a base extent: when a row
    // overflows, the engine reclaims the excess from every child in proportion
    // to its slack, which squeezed the chrome to a single cell and left the
    // code hanging off it. Chrome is not negotiable — a long line reflows, the
    // line number does not shrink.
    auto strip = SizeSpec.fixed(gutterWidth(channels, 0));
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
    separator = cells between the chrome and the code. `1` reads as a column
        of its own; `0` is for a last channel that must abut the code, like a
        diff marker whose tinted band runs into the row it marks

Returns: the composed row, or `content` unchanged when no channel is enabled —
    so a document with every channel off is exactly the tree it was before
    gutters existed.
*/
uint withGutter(ref Builder b, const(GutterChannel)[] channels, size_t line,
    uint content, int separator = 1)
{
    return joinStrip(b, gutterRow(b, channels, line), content, separator);
}

/// The strip and the code, separated by `separator` cells.
private uint joinStrip(ref Builder b, uint strip, uint content, int separator)
{
    if (strip == 0)
        return content;
    return b.add(Widget(
        kind: WidgetKind.row,
        children: [strip, content],
        gap: separator,
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

/**
As $(LREF withGutter), but with the row's cells given directly.

The diff view's form: a row there is a hunk row rather than a source line, so
it computes its own old/new/marker cells and hands them over.
*/
uint withGutterCells(ref Builder b, const(GutterChannel)[] channels,
    const(GutterCell)[] cells, uint content, int separator = 1)
{
    return joinStrip(b, gutterRowOf(b, channels, cells), content, separator);
}

/**
`document` with `channels` beside it as sibling columns, one cell per $(I visual
row).

The post-layout form, and the one a file's line-number gutter needs. A document
whose rows are one per source line can place its chrome as it builds
($(LREF withGutter)); most cannot. A wrapped paragraph is two visual rows, a
heading is one, a blank source line is none at all — so there is nothing to
index by line, and the only way to know which row carries which line is to lay
the document out and read $(REF DocRow, sparkles,ui,state)`.srcStart` back.

That makes the composition a pair of passes: lay out the document, build the
cells from its rows, wrap it in this, lay out again. Sibling columns are
correct here for the same reason they are wrong before layout — the rows
already exist, so nothing can drift.

Params:
    b = the builder the document was added to, still usable after `finish`
    channels = the strips, in left-to-right order; `cells` indexed by visual row
    rowCount = the document's height in visual rows
    document = the laid-out document's root

Returns: the composed root, or `document` unchanged when no channel is enabled.
*/
uint withGutterColumns(ref Builder b, const(GutterChannel)[] channels,
    size_t rowCount, uint document)
{
    uint[] columns;
    foreach (ch; channels.enabledOf)
    {
        uint[] cells;
        foreach (row; 0 .. rowCount)
            cells ~= cellWidget(b, ch, row < ch.cells.length ? &ch.cells[row] : null);
        auto w = SizeSpec.fixed(ch.width);
        w.min = w.value;   // chrome does not shrink; see `stripOf`
        columns ~= b.add(Widget(
            kind: WidgetKind.column,
            children: cells,
            width: w,
        ));
    }
    if (columns.length == 0)
        return document;
    return b.add(Widget(
        kind: WidgetKind.row,
        children: columns ~ document,
        gap: 1,
    ));
}

@("ui.components.gutter.postLayoutColumnsAlignToVisualRows")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : documentRows;
    import sparkles.ui.widget : Builder, TextSpan;
    import sparkles.ui.wrap : TextWrap;

    // A document whose rows are *not* one per source line: the first line
    // wraps into two visual rows. This is the case a per-line channel cannot
    // serve, and the reason this form exists.
    auto b = Builder();
    TextSpan[] a = [TextSpan("aaaa bbbb cccc", srcStart: 0, srcEnd: 14)];
    TextSpan[] c = [TextSpan("short", srcStart: 15, srcEnd: 20)];
    uint[] rows = [
        b.add(Widget(kind: WidgetKind.rich, spans: a, wrap: TextWrap.greedy)),
        b.add(Widget(kind: WidgetKind.rich, spans: c, wrap: TextWrap.greedy)),
    ];
    const docRoot = b.container(WidgetKind.column, rows);

    // Pass one: how many visual rows, and what does each carry?
    auto pass1 = b.finish(docRoot);
    const dr = documentRows(pass1, layout(pass1, Constraints(maxW: 10)));
    assert(dr.length == 3, "the first line wrapped");

    // One cell per visual row, numbered by source line, blank on a
    // continuation — `NUM1`, which is a property of the rows and not of the
    // source.
    auto cells = new GutterCell[](dr.length);
    size_t prev = size_t.max;
    foreach (i, r; dr)
    {
        const line = r.srcStart == size_t.max ? size_t.max
            : (r.srcStart < 15 ? 0 : 1);
        cells[i] = line == prev || line == size_t.max
            ? blankCell(2) : cellOf(line == 0 ? "1" : "2", 2);
        prev = line;
    }

    // Pass two: the same builder, re-rooted around the document.
    auto tree = b.finish(withGutterColumns(b,
        [GutterChannel(id: "line", width: 2, cells: cells)], dr.length, docRoot));
    auto frames = layout(tree, Constraints(maxW: 13));

    const out_ = documentRows(tree, frames);
    assert(out_.length == 3);
    assert(out_[0].text == " 1aaaa bbbb");
    assert(out_[1].text == "  cccc", "the continuation row is unnumbered");
    assert(out_[2].text == " 2short");
    // And the chrome still never reaches the content.
    assert(out_[0].sourceText == "aaaa bbbb");
    assert(out_[1].sourceText == "cccc");
}

/**
The order in which providers win the shared icon slot, highest first.

$(B Why an order exists at all.) Most channels are lanes: coverage counts and
line numbers each own a strip and never contend. Icons are not. A breakpoint,
a fold arrow, a diagnostic badge and a bookmark all want the same one cell, and
giving each a lane of its own converts contention into width — five providers
would push the code five columns right on a file where at most one of them ever
has something to say on a given line. So they share a strip and the strip needs
a rule.

The rule is $(I actionability): what the reader would lose by not seeing it.
A stopped debugger is the most urgent thing on the screen and a fold arrow the
least — the arrow's information is also carried by the code's own shape, and
a folded region shows a placeholder besides.

Only $(LREF foldPriority) has a producer in this repository today; the rest name
the slots the design reserves, so a later provider picks an existing rank rather
than inventing one and quietly outranking everything.
*/
enum int debugCursorPriority = 60;  /// the instruction pointer, while stopped
enum int breakpointPriority  = 50;  /// set, conditional, or a logpoint
enum int diagnosticPriority  = 40;  /// the row's most severe diagnostic
enum int bookmarkPriority    = 30;  /// a reader's own mark
enum int foldPriority        = 10;  /// a foldable region's arrow

/**
One provider's claim on one row of a merged channel.

A claim carries the text rather than a built cell so that merging never copies
a `GutterCell` — the losing claims are dropped without ever having allocated,
and the winner is rendered to the channel's width once.
*/
struct IconClaim
{
    size_t row;             /// the visual row claimed
    int priority;           /// higher wins; see $(LREF foldPriority) and friends
    const(char)[] glyph;    /// what to show, one cell wide by convention
    Slot slot = Slot.gutter;
    size_t hitId;           /// `0` for a decorative icon
}

/**
`claims` resolved to one cell per row — the merged-slot counterpart to a
channel whose cells a single producer fills.

Ties keep the $(I first) claim at that priority, so a provider that emits its
own rows in a deterministic order gets a deterministic slot. Claims past
`rowCount` are dropped rather than being an error: a provider that describes
the whole file may run past a folded document's rows.

Params:
    claims = every provider's claims, in any order
    rowCount = the document's height in visual rows
    width = the channel's width in cells
    alignEnd = right-align the glyph in the strip; icons left-align by default

Returns: `rowCount` cells, blank where nothing was claimed.
*/
GutterCell[] mergedCells(scope const(IconClaim)[] claims, size_t rowCount,
    int width, bool alignEnd = false)
{
    auto cells = new GutterCell[](rowCount);
    foreach (i; 0 .. rowCount)
        cells[i] = blankCell(width);

    auto won = new int[](rowCount);
    won[] = int.min;
    foreach (ref const claim; claims)
    {
        if (claim.row >= rowCount || claim.priority <= won[claim.row])
            continue;
        won[claim.row] = claim.priority;
        cells[claim.row] = cellOf(claim.glyph, width, claim.slot,
            alignEnd: alignEnd, paintBackground: false, hitId: claim.hitId);
    }
    return cells;
}

@("ui.components.gutter.mergedCellsResolveTheSharedSlotByPriority")
@safe unittest
{
    // The contention the merged slot exists for: three providers, one cell.
    const claims = [
        IconClaim(row: 0, priority: foldPriority, glyph: "▾", hitId: 7),
        IconClaim(row: 0, priority: breakpointPriority, glyph: "●", hitId: 9),
        IconClaim(row: 1, priority: foldPriority, glyph: "▸", hitId: 8),
        IconClaim(row: 9, priority: breakpointPriority, glyph: "●"),
    ];
    const cells = mergedCells(claims, 3, 1);

    assert(cells.length == 3);
    // The breakpoint outranks the fold arrow, and takes its hit id with it —
    // the winner owns the click as well as the pixels.
    assert(cells[0].text[] == "●" && cells[0].hitId == 9);
    assert(cells[1].text[] == "▸" && cells[1].hitId == 8);
    assert(cells[2].text[] == " " && cells[2].hitId == 0);

    // A claim past the document's rows is dropped, not an error.
    assert(mergedCells([IconClaim(row: 5, priority: 1, glyph: "x")], 2, 1)
        .length == 2);

    // Ties keep the first claim, so a provider's own order decides.
    const tied = mergedCells([
        IconClaim(row: 0, priority: 5, glyph: "a"),
        IconClaim(row: 0, priority: 5, glyph: "b"),
    ], 1, 1);
    assert(tied[0].text[] == "a");
}
