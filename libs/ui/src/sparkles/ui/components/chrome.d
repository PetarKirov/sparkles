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

import sparkles.ui.geometry : cellsOf, Insets, Point, SizeSpec;
import sparkles.ui.state : PressState, ScrollAxis, ScrollbarState, ScrollState,
    scrollbarThumb;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Visibility, Widget, WidgetKind;

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

/// ditto — driven by the whole machine (`STM9`/`IXB1`): the state carries
/// the offset and the axis picks the container (a column for a vertical
/// bar, a row for a horizontal one; pass row glyphs like `━`/`─` for it).
uint scrollbar(ref Builder b, in ScrollbarState sb, long content,
    long viewport, int track, in ScrollbarGlyphs glyphs = ScrollbarGlyphs.init)
{
    const thumb = sb.thumb(content, viewport, track);
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
    return b.container(sb.axis == ScrollAxis.vertical
        ? WidgetKind.column : WidgetKind.row, cells);
}

/**
A header / status bar (`WGT17`): a full-width band (the `chrome` slot) with
leading, center and trailing segment groups separated by `grow` spacers — the
spelling `LAY8` prescribes for distribution. Any of the groups may be empty.
*/
uint headerBar(ref Builder b, uint[] leading, uint[] center = null,
    uint[] trailing = null, bool focused = false)
{
    const s1 = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    const s2 = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    return b.add(Widget(
        kind: WidgetKind.row,
        children: leading ~ s1 ~ center ~ s2 ~ trailing,
        // A focused pane's bar renders on the accented band, so the pane
        // holding the input focus is visible at a glance.
        slot: focused ? Slot.chromeFocused : Slot.chrome,
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

/**
A segmented action bar (`WGT15` in part, `IXB9`): equal-width tappable
segments across the parent's width, each addressed by a hit id.

The point is not that a bar is hard to draw — it is that a hand-rolled one
computes its geometry $(B twice), once to paint and once to hit-test, and the
two drift. Here the segments are laid out once and the hit rects come from
$(REF hoverTargets, sparkles,ui,state) over those same frames, so
painted-and-tappable cannot disagree:

$(LIST
    * $(B invisible but live) is unrepresentable — `Visibility.collapsed`
        removes a node from flow $(I and) from `hoverTargets`, so hiding the
        bar disarms it; the host cannot forget the second gate.
    * $(B overlapping owners) resolve deterministically — hit ids arbitrate
        topmost-wins, instead of two affordances both consuming one press
        because one block happened to run first.
    * $(B mis-centred labels) cannot occur — the layout engine centres via
        `LAY8` alignment over `cellsOf`, so no host measures a UTF-8 label
        with `.length` and pushes it off-centre.
)

`hitBase` is the first id; segment `i` gets `hitBase + i`, so a host maps an
activation back with `id - hitBase`. Pass the `press` state to render the
armed segment pressed. A `label` that is empty renders an empty segment,
which still takes its share of the width — a bar's segments stay aligned
across rebuilds even when one has nothing to say.
*/
uint actionBar(ref Builder b, scope const(string)[] labels, size_t hitBase,
    in PressState press = PressState.init)
{
    auto segs = new uint[](labels.length);
    foreach (i, label; labels)
    {
        const id = hitBase + i;
        const caption = b.add(Widget(
            kind: WidgetKind.text,
            // `string`, not `const(char)[]`: this is built every frame by a
            // GUI host, and taking immutable labels keeps that path free of a
            // per-segment `idup`.
            text: label,
            slot: press.isArmed(id) ? Slot.chromeAccent : Slot.chrome,
        ));
        segs[i] = b.add(Widget(
            kind: WidgetKind.column,
            children: [caption],
            // Equal shares of the bar: every segment grows with weight 1, so
            // the split is the layout engine's, not `width / count` computed
            // by each caller.
            width: SizeSpec.grow(),
            // LAY8 centring — the reason a host never measures a label.
            alignX: Alignment.center,
            // The whole segment is the target, not just the glyphs: a fingertip
            // lands between labels as often as on one.
            hitId: id,
            slot: press.isArmed(id) ? Slot.chromeFocused : Slot.chrome,
            paintBackground: true,
        ));
    }
    return b.add(Widget(
        kind: WidgetKind.row,
        children: segs,
        slot: Slot.chrome,
        paintBackground: true,
        stretch: true,
        height: SizeSpec.fixed(1),
    ));
}

/**
A tab strip (`WGT23`): a row of labelled tabs, one $(B active), over shared
content that only the active tab supplies.

The same discipline as $(LREF actionBar) — segments laid out once, hit rects
from $(REF hoverTargets, sparkles,ui,state) over those very frames, so painted
and tappable cannot drift — plus the one thing a bar does not have: a
$(I selected) segment, which is a different state from an $(I armed) one. A
press arms, a release over the same tab activates (`STM10`), and the active
tab stays lit after the pointer leaves; conflating the two is why hand-rolled
strips flicker the wrong tab during a drag.

Tabs are as wide as what they say (`fitLabels`, the usual look — a file name
should not be padded to a fifth of the window); with `fitLabels: false` each
tab instead takes its label plus an equal share of the leftover width, the
$(LREF actionBar) behaviour, for callers that want a segmented control.
Either way the widths come from `cellsOf`, so a UTF-8 label is measured in
cells and never by `.length`.

Consumers are deliberately unrelated: an application selecting one of several
documents, and a markdown renderer showing one of a code group's fences. That
is the test of whether this belongs in the toolkit at all.

`hitBase` is the first id; tab `i` gets `hitBase + i`, so an activation maps
back with `id - hitBase`. Pass `ids` instead when the caller has its own
identity scheme — a source-anchored one, say — and the strip uses those
verbatim.
*/
/// Border caps for a strip embedded IN a border line (the markdown fence
/// header): `left` leads the strip, `separator` stands between tabs, and
/// `right` closes it into the continuing line — all in `Slot.border` — so
/// the tabs read as a boxed part of the border, not chrome floating on it:
/// `│ tab │ tab ├──`. The caller typically stacks a matching top-border
/// row (`╭──┬──╮`) above; $(LREF tabStripTopBorder) builds it from the
/// same widths.
struct TabCaps
{
    string left;
    string separator;
    string right;
}

/// The `╭──┬──╮` row that boxes a capped strip from above: corners at the
/// strip's edges, a `┬` over each separator — junctioning into the capped
/// row's `│`s below. Widths follow the strip's own tab sizing.
uint tabStripTopBorder(ref Builder b, scope const(string)[] labels)
{
    string line = "╭";
    foreach (i, label; labels)
    {
        foreach (_; 0 .. cellsOf(label) + 2)
            line ~= "─";
        line ~= i + 1 < labels.length ? "┬" : "╮";
    }
    return b.add(Widget(kind: WidgetKind.text, text: line, slot: Slot.border));
}

uint tabStrip(ref Builder b, scope const(string)[] labels, size_t active,
    size_t hitBase, in PressState press = PressState.init,
    bool fitLabels = true, scope const(size_t)[] ids = null,
    TabCaps caps = TabCaps.init)
{
    uint capGlyph(string g)
        => b.add(Widget(kind: WidgetKind.text, text: g, slot: Slot.border));

    auto segs = new uint[](0);
    segs.reserve(labels.length + 1);
    foreach (i, label; labels)
    {
        // Ids default to `hitBase + i`, but a caller with its own identity
        // scheme supplies them: a markdown code group anchors each tab to
        // its fence's source offset, so two groups on one page cannot mint
        // the same id and a re-parse cannot renumber them.
        const id = i < ids.length ? ids[i] : hitBase + i;
        const isActive = i == active;
        const armed = press.isArmed(id);
        const caption = b.add(Widget(
            kind: WidgetKind.text,
            text: label,
            // Three distinct states, because they mean three things: this
            // one is showing, this one is being pressed, this one is idle.
            slot: isActive ? Slot.chromeAccent
                : armed ? Slot.chromeFocused : Slot.gutter,
            textStyle: TextStyle(bold: isActive),
        ));
        const body = b.add(Widget(
            kind: WidgetKind.column,
            children: [caption],
            // A tab is its label plus one cell of breathing room either
            // side; growing shares the leftover instead.
            width: fitLabels
                ? SizeSpec.fixed(cast(int) cellsOf(label) + 2)
                : SizeSpec.grow(),
            alignX: Alignment.center,
            // The whole tab is the target, not just the glyphs.
            hitId: id,
            slot: isActive ? Slot.chromeFocused : Slot.chrome,
            // A CAPPED strip is line-drawn: solid bands under hairline
            // walls read as floating blocks (the GUI especially), so only
            // the active tab keeps a subtle fill inside its walls.
            paintBackground: !caps.left.length || isActive,
        ));
        if (caps.left.length)
        {
            // Capped: `│` walls between the tabs, the trailing cap
            // junctioning the strip into the continuing border line.
            if (i == 0)
                segs ~= capGlyph(caps.left);
            segs ~= body;
            segs ~= capGlyph(i + 1 < labels.length
                ? caps.separator : caps.right);
        }
        else
            segs ~= body;
    }
    // A filler tail so the strip's background spans the full width even when
    // the tabs do not — and so nothing beyond the last tab is hit-testable.
    // A CAPPED strip skips it: the surrounding border line is the filler.
    if (!caps.left.length)
        segs ~= b.add(Widget(
            kind: WidgetKind.column,
            width: SizeSpec.grow(),
            slot: Slot.chrome,
            paintBackground: true,
        ));
    return b.add(Widget(
        kind: WidgetKind.row,
        children: segs,
        slot: Slot.chrome,
        paintBackground: !caps.left.length,
        stretch: true,
        height: SizeSpec.fixed(1),
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

@("ui.components.chrome.actionBarHitsMatchPaint")
@safe unittest
{
    import sparkles.ui.state : hoverTargets, HoverState;
    import sparkles.input : PointerAction, PointerEvent;

    // Five segments across 30 cells, ids 100..104 — hue's toolbar shape.
    enum base = 100;
    auto b = Builder();
    const bar = actionBar(b, ["◀ thm", "thm ▶", "view", "tree", "ln №"], base);
    Widget colW = Widget(kind: WidgetKind.column, children: [bar],
        width: SizeSpec.fixed(30));
    const col = b.add(colW);
    auto tree = b.finish(col);
    auto frames = layout(tree);

    // The hit rects come from the SAME frames the painter uses — this is the
    // invariant the hand-rolled bar could not state, having computed
    // `screenW / 5` independently at each end, ~1200 lines apart (IXR27).
    const targets = hoverTargets(tree, frames);
    HoverState h;
    foreach (i; 0 .. 5)
    {
        // A point inside segment i resolves to segment i's id.
        const x = cast(int)(i * 6 + 3);
        h.update(PointerEvent(action: PointerAction.move, pos: Point(x, 0)),
            targets);
        assert(h.hot == base + i, "segment hit mismatch");
    }

    // The segments TILE the bar: each starts where the previous ended, and
    // together they span it exactly — no gap a press falls into, no overlap
    // two segments both claim.
    const segs = tree.nodes[bar].children;
    assert(segs.length == 5);
    int edge = frames[bar].rect.x;
    foreach (s; segs)
    {
        assert(frames[s].rect.x == edge, "segments must be contiguous");
        edge += frames[s].rect.width;
    }
    assert(edge == frames[bar].rect.x + frames[bar].rect.width,
        "segments must span the bar exactly");

    // Centring is the engine's, over display COLUMNS. "◀ thm" is 7 bytes and
    // 5 columns; measuring it with `.length` (which is what the hand-rolled
    // bar did) makes the label ~40 % too wide and pushes it off-centre. Each
    // caption must sit within its own segment, and centred in it.
    foreach (i, s; segs)
    {
        const cap = frames[tree.nodes[s].children[0]].rect;
        const seg = frames[s].rect;
        assert(cap.x >= seg.x && cap.x + cap.width <= seg.x + seg.width,
            "a caption escaped its segment");
        // Centred: the slack is shared between the two sides, ±1 for an odd
        // remainder.
        const before = cap.x - seg.x;
        const after = (seg.x + seg.width) - (cap.x + cap.width);
        assert(before - after <= 1 && after - before <= 1,
            "caption is not centred in its segment");
    }
}

@("ui.components.chrome.actionBarCollapsedIsNotTappable")
@safe unittest
{
    import sparkles.ui.state : hoverTargets;

    // The defect this makes unrepresentable: hue's bar was painted under an
    // `!inputMode` gate while its tap handler had no such gate, so during a
    // '/' search the bar was invisible and still live. `hoverTargets` skips
    // any non-visible node, so one visibility assignment governs both — the
    // host cannot set the paint gate and forget the hit gate.
    //
    // (`hidden` behaves identically here; `collapsed` additionally drops the
    // bar from layout flow, which is what a host wants for a bar that yields
    // its row rather than one that merely goes quiet.)
    auto b = Builder();
    const bar = actionBar(b, ["a", "b"], 7);
    b.nodes[bar].visibility = Visibility.collapsed;
    Widget colW = Widget(kind: WidgetKind.column, children: [bar],
        width: SizeSpec.fixed(10));
    const col = b.add(colW);
    auto tree = b.finish(col);
    auto frames = layout(tree);

    assert(hoverTargets(tree, frames).length == 0,
        "a collapsed bar must not be hit-testable");
}

@("ui.components.chrome.actionBarArmedSegmentPaintsPressed")
@safe unittest
{
    // Arming is visible: the armed segment takes the focused chrome slot, so
    // a press has feedback without the host tracking which one it pressed.
    auto b = Builder();
    const press = PressState.init.pressed(21);
    const bar = actionBar(b, ["x", "y", "z"], 20, press);
    auto tree = b.finish(bar);

    const segs = tree.nodes[bar].children;
    assert(tree.nodes[segs[0]].slot == Slot.chrome);
    assert(tree.nodes[segs[1]].slot == Slot.chromeFocused); // id 21
    assert(tree.nodes[segs[2]].slot == Slot.chrome);
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

@("ui.components.chrome.tabStripFitsLabelsAndHitsMatchPaint")
@safe unittest
{
    import sparkles.ui.state : hoverTargets, HoverState;
    import sparkles.input : PointerAction, PointerEvent;

    // Three tabs sized to their labels, the second one showing.
    enum base = 200;
    auto b = Builder();
    const strip = tabStrip(b, ["config.js", "config.ts", "π.md"], 1, base);
    const col = b.add(Widget(kind: WidgetKind.column, children: [strip],
        width: SizeSpec.fixed(40)));
    auto tree = b.finish(col);
    auto frames = layout(tree);

    // Widths are label CELLS plus one either side — "π.md" is 4 cells, not
    // the 5 bytes a `.length` measurement would have produced.
    const tabs = tree.nodes[strip].children;
    assert(frames[tabs[0]].rect.width == 11);
    assert(frames[tabs[1]].rect.width == 11);
    assert(frames[tabs[2]].rect.width == 6);
    // The filler tail takes the remainder, so the strip spans the full width.
    assert(frames[tabs[3]].rect.width == 12);

    // Hits come from those same frames (the IXR27 invariant).
    const targets = hoverTargets(tree, frames);
    HoverState h;
    h.update(PointerEvent(action: PointerAction.move, pos: Point(5, 0)),
        targets);
    assert(h.hot == base + 0);
    h.update(PointerEvent(action: PointerAction.move, pos: Point(15, 0)),
        targets);
    assert(h.hot == base + 1);
    h.update(PointerEvent(action: PointerAction.move, pos: Point(24, 0)),
        targets);
    assert(h.hot == base + 2);
    // Past the last tab is filler: hit-testable by nothing.
    h.update(PointerEvent(action: PointerAction.move, pos: Point(35, 0)),
        targets);
    assert(h.hot == 0, "the tail is not a tab");
}

@("ui.components.chrome.tabStripDistinguishesActiveFromArmed")
@safe unittest
{
    // Active and armed are different states: the showing tab stays lit while
    // a DIFFERENT one is held down, which is what a strip that conflates
    // them gets wrong mid-press.
    auto b = Builder();
    const strip = tabStrip(b, ["one", "two"], 0, 10,
        PressState.init.pressed(11));
    auto tree = b.finish(strip);
    const tabs = tree.nodes[strip].children;
    assert(tree.nodes[tabs[0]].slot == Slot.chromeFocused, "active tab");
    assert(tree.nodes[tree.nodes[tabs[0]].children[0]].textStyle.bold);
    assert(tree.nodes[tabs[1]].slot == Slot.chrome, "armed is not active");
    assert(tree.nodes[tree.nodes[tabs[1]].children[0]].slot
        == Slot.chromeFocused, "…but the armed label is lit");

    // `fitLabels: false` grows instead: every segment takes its label plus
    // the SAME share of the leftover, so the strip tiles exactly (the
    // actionBar behaviour — not equal widths, which unequal labels forbid).
    auto e = Builder();
    const seg = tabStrip(e, ["a", "bbbbb"], 0, 10, PressState.init,
        fitLabels: false);
    const col = e.add(Widget(kind: WidgetKind.column, children: [seg],
        width: SizeSpec.fixed(30)));
    auto etree = e.finish(col);
    auto eframes = layout(etree);
    const segs = etree.nodes[seg].children;
    const share0 = eframes[segs[0]].rect.width - 1; // minus "a"
    const share1 = eframes[segs[1]].rect.width - 5; // minus "bbbbb"
    assert(share0 == share1, "the leftover is shared equally");
    int total;
    foreach (sgi; segs)
        total += eframes[sgi].rect.width;
    assert(total == 30, "the segments tile the strip");
}
