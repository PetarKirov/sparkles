/**
Application-chrome widget views (`WGT9`/`WGT10`/`WGT17`/`WGT18`): the scroll
view, scrollbar, header/status bar and line-number gutter every hue backend
currently hand-rolls — expressed $(B once) as widget subtrees over the layout
engine's viewport primitive and the state level's machines.

Each function is a pure view: it appends a subtree to a
$(REF Builder, sparkles,ui,widget) and returns its root index. Behavior lives
in $(MREF sparkles,ui,state) (the scroll offset, the thumb formula); these own
only slots, glyphs and arrangement.
*/
module sparkles.ui.components.chrome;

import std.conv : text;

import sparkles.ui.geometry : Insets, Point, SizeSpec;
import sparkles.ui.state : ScrollState, scrollbarThumb;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind;

@safe:

/**
A vertical scroll view (`WGT9`): a viewport of `height` rows that clips
`content` and shifts it by `scroll.offset` — the `LAY7` primitive with the
scroll state machine plugged in. `key` addresses the element's state across
rebuilds (`WGT5`); pass the view's stable identity when the offset must
survive a rebuild.
*/
uint scrollView(ref Builder b, uint content, int height,
    in ScrollState scroll, size_t key = 0)
{
    return b.add(Widget(
        kind: WidgetKind.column,
        children: [content],
        height: SizeSpec.fixed(height),
        clipY: true,
        childOffset: Point(0, cast(int) scroll.offset),
        key: key,
    ));
}

/// The scrollbar's charset (colors come from the `track`/`thumb` slots; the
/// characters are theme-glyph data, defaulting to the unicode blocks).
struct ScrollbarGlyphs
{
    dchar thumb = '█';
    dchar track = '│';
}

/**
A vertical scrollbar (`WGT10`): a one-column track of `track` rows whose thumb
comes from the $(B one) thumb formula ($(REF scrollbarThumb, sparkles,ui,state))
— every backend renders this; none re-derives the geometry.
*/
uint scrollbar(ref Builder b, long content, long viewport, long offset,
    int track, in ScrollbarGlyphs glyphs = ScrollbarGlyphs.init)
{
    const thumb = scrollbarThumb(content, viewport, offset, track);
    auto cells = new uint[](track > 0 ? track : 0);
    foreach (i; 0 .. cells.length)
    {
        const inThumb = i >= thumb.start && i < thumb.start + thumb.extent;
        cells[i] = b.add(Widget(
            kind: WidgetKind.glyph,
            glyph: inThumb ? glyphs.thumb : glyphs.track,
            slot: inThumb ? Slot.thumb : Slot.track,
        ));
    }
    return b.container(WidgetKind.column, cells);
}

/**
A header / status bar (`WGT17`): a full-width band (the `chrome` slot) with
leading, center and trailing segment groups separated by `grow` spacers — the
spelling `LAY8` prescribes for distribution. Any of the groups may be empty.
*/
uint headerBar(ref Builder b, uint[] leading, uint[] center = null,
    uint[] trailing = null)
{
    const s1 = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    const s2 = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    return b.add(Widget(
        kind: WidgetKind.row,
        children: leading ~ s1 ~ center ~ s2 ~ trailing,
        slot: Slot.chrome,
        paintBackground: true,
        stretch: true, // span the parent column edge-to-edge
        padding: Insets.symmetric(0, 1),
        gap: 1,
    ));
}

/**
A line-number gutter (`WGT18`): `count` rows starting at `firstLine`,
right-aligned in a `width`-cell column via the container's own `LAY8`
alignment (no hand-padded strings).
*/
uint gutter(ref Builder b, long firstLine, int count, int width)
{
    auto rows = new uint[](count > 0 ? count : 0);
    foreach (i; 0 .. rows.length)
        rows[i] = b.add(Widget(
            kind: WidgetKind.text,
            text: text(firstLine + i),
            slot: Slot.gutter,
        ));
    return b.add(Widget(
        kind: WidgetKind.column,
        children: rows,
        width: SizeSpec.fixed(width),
        alignX: Alignment.end,
    ));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.base.term_color : RgbColor;
}

@("ui.components.chrome.scrollbarRendersTheOneThumbFormula")
@safe unittest
{
    // 30 lines in a 10-line viewport on a 6-cell track: thumb extent 2.
    auto b = Builder();
    const bar = scrollbar(b, 30, 10, 10, 6);
    auto tree = b.finish(bar);
    auto frames = layout(tree);
    assert(frames[bar].rect.width == 1 && frames[bar].rect.height == 6);

    auto ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));
    assert(ops.length == 6);
    size_t thumbCells;
    foreach (op; ops)
        if (op.glyph == '█')
        {
            thumbCells++;
            assert(op.slot == Slot.thumb);
        }
    assert(thumbCells == 2);
}

@("ui.components.chrome.headerBarDistributesSegments")
@safe unittest
{
    // title …spacer… center …spacer… hint, in a 30-cell column.
    auto b = Builder();
    const title = b.add(Widget(kind: WidgetKind.text, text: "hue",
        slot: Slot.chromeAccent));
    const mid = b.add(Widget(kind: WidgetKind.text, text: "file.d"));
    const hint = b.add(Widget(kind: WidgetKind.text, text: "q quit"));
    const bar = headerBar(b, [title], [mid], [hint]);
    Widget colW = Widget(kind: WidgetKind.column, children: [bar],
        width: SizeSpec.fixed(30));
    const col = b.add(colW);
    auto frames = layout(b.finish(col));

    assert(frames[bar].rect.width == 30);            // stretch spans the column
    assert(frames[title].rect.x == 1);               // after the band padding
    assert(frames[hint].rect.right == 29);           // flush right, before padding
    // The center segment sits between the spacers, near the middle.
    const cx = frames[mid].rect.x + frames[mid].rect.width / 2;
    assert(cx >= 13 && cx <= 17);
}

@("ui.components.chrome.gutterRightAlignsNumbers")
@safe unittest
{
    auto b = Builder();
    const g = gutter(b, 98, 3, 4); // 98, 99, 100 in 4 cells
    auto tree = b.finish(g);
    auto frames = layout(tree);

    assert(frames[g].rect.width == 4);
    const rows = tree.nodes[g].children;
    assert(tree.nodes[rows[0]].text == "98" && frames[rows[0]].rect.x == 2);
    assert(tree.nodes[rows[2]].text == "100" && frames[rows[2]].rect.x == 1);
}

@("ui.components.chrome.scrollViewClipsAndKeys")
@safe unittest
{
    import sparkles.ui.state : ElementStore, elementKeys;

    auto b = Builder();
    uint[] rows;
    foreach (t; ["zero", "one", "two", "three"])
        rows ~= b.add(Widget(kind: WidgetKind.text, text: t));
    const content = b.container(WidgetKind.column, rows);
    const view = scrollView(b, content, 2, ScrollState(1), key: 42);
    auto tree = b.finish(view);

    auto frames = layout(tree);
    assert(frames[view].rect.height == 2);
    assert(frames[rows[0]].rect.y == -1); // scrolled above the viewport

    auto ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));
    // pushClip + the two visible rows + popClip.
    size_t textOps;
    foreach (op; ops)
        textOps += op.kind == OpKind.textRun;
    assert(textOps == 2);

    // The view's element identity is in the tree for the state store.
    assert(elementKeys(tree) == [42]);
}
