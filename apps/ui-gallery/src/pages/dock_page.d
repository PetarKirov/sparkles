/**
The Dock page: an arrangement of panes as a $(B value), and everything that
follows from that.

A dock is the piece applications most often rebuild badly, because the parts
look separable and are not: where the panes are, which one has focus, who owns
the pointer during a drag, which divider a drag resizes, and where an event
goes are one decision, and splitting them across a frame loop is how a hit rect
comes to disagree with the thing it is supposed to be under.

So the page shows the layout as data first — the arena, rendered by walking it —
and then the three interactions that read the same value: the divider drag, the
tab strip, and drag-to-redock. The hint a drag paints is computed from the same
`DockDrag` the drop will act on, which is the property worth seeing: the preview
cannot promise a region the release will not fill.

Everything here works from the keyboard too. Not politeness — `DCK12`: a
container whose only route to a feature is a drag has no answer for a target
without a pointer.
*/
module pages.dock_page;

import std.conv : text;

import sparkles.input : Event, Key, KeyEvent, Point, PointerEvent;
import sparkles.ui.components.chrome : dockHint, tabStrip;
import sparkles.ui.dock : DockAxis, DockContainer, DockKind, DockLayout,
    DockZone, PaneId, RouteKind;
import sparkles.ui.geometry : Rect, Size, SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import kit;
import scrollbars : rectOf;
import state : GalleryState, hitDock;

@safe:

/// The demo's panes. Ids, not indices: the container resolves them, and a
/// restore that no longer knows one simply drops it (`DCK2`).
enum PaneId sidePane = 1, docPane = 2, notesPane = 3;

/// The demo area's height in cells — fixed, so the page's prose does not
/// reflow while a divider moves.
enum int dockRows = 12;

/// ditto
static immutable string[] keys = [
    "h l resize", "[ ] tab", "f focus", "w e n s re-dock", "r reset",
];

/// Builds the starting arrangement: a sidebar beside a tabbed group.
DockLayout demoLayout()
{
    DockLayout l;
    const s = l.addLeaf(sidePane, extent: 18, minExtent: 8);
    const d = l.addLeaf(docPane);
    const n = l.addLeaf(notesPane);
    l.nodes[s].headerExtent = 1;
    l.nodes[s].title = "explorer";
    l.nodes[d].headerExtent = 1;
    l.nodes[d].title = "document";
    l.nodes[n].headerExtent = 1;
    l.nodes[n].title = "notes";
    const g = l.addTabs([d, n]);
    l.root = l.addSplit(DockAxis.horizontal, [s, g]);
    return l;
}

/// Ensures the page's container is built and sized to the demo area. Called
/// from the view (and from every handler), because a page cannot be sure the
/// shell laid it out at this width last frame.
private void ensure(ref GalleryState s)
{
    if (!s.dock.layout.nodes.length)
    {
        s.dock.layout = demoLayout();
        s.dock.focused = docPane;
    }
    s.dock.arrange(Rect(0, 0, s.contentWidth, dockRows));
}

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    // Normally the container is already arranged — `step` does it every
    // frame, before the view runs, because arranging is a mutation and a
    // view may not mutate. But the catalog sweep renders every page against
    // a DEFAULT state, where `step` has never run, so the view must be
    // total over an empty arena rather than indexing into one.
    if (s.dock.layout.nodes.length)
        return viewWith(b, s.dock, s);
    DockContainer fresh;
    fresh.layout = demoLayout();
    fresh.focused = docPane;
    fresh.arrange(Rect(0, 0, s.contentWidth, dockRows));
    return viewWith(b, fresh, s);
}

private uint viewWith(ref Builder b, in DockContainer c, in GalleryState s)
{
    const w = s.contentWidth;
    uint[] body_;
    body_ ~= heading(b, "Dock · panes as a value");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "The arrangement is a flat arena of splits, tabbed groups and pane "
        ~ "leaves. Everything below is derived from it: the rects, the tab "
        ~ "strips, the reserved header rows, and where a pointer event goes. "
        ~ "Nothing here keeps a second copy of any of that.", w);
    body_ ~= spacer(b);

    // ONE hit id, on the arrangement's root: it exists to locate the demo's
    // origin so a pointer can be translated into the container's space, and
    // the container resolves everything inside it from there. Stamping the
    // id on each pane instead would make `rectOf` answer with whichever pane
    // happens to come first — right only while that pane sits at the origin,
    // which a re-dock is free to change.
    const arrangement = b.add(Widget(
        kind: WidgetKind.column,
        children: [renderNode(b, c, c.layout.root)],
        width: SizeSpec.grow(),
        height: SizeSpec.fixed(dockRows),
        hitId: hitDock,
    ));
    body_ ~= section(b, "the arrangement", [arrangement]);
    body_ ~= spacer(b);

    body_ ~= section(b, "the container", [
        kv(b, "focused", paneName(c.focused), 16, Slot.chromeAccent),
        kv(b, "panes", text(c.frames.panes.length, " visible of ",
            c.layout.panes().length), 16),
        kv(b, "dividers", text(c.frames.dividers.length), 16),
        kv(b, "tabs", text(c.frames.tabs.length), 16),
        kv(b, "resizing", c.resizing ? "yes" : "no", 16),
    ]);
    body_ ~= spacer(b);

    // The drag hint, when one is in flight. The same value that will be
    // dropped — a host cannot show a region the release will not fill.
    const drag = s.dock.dragHint();
    if (drag.active)
    {
        body_ ~= section(b, "drag in flight", [
            kv(b, "moving", paneName(drag.pane), 16, Slot.chromeAccent),
            kv(b, "over", drag.target ? paneName(drag.target) : "nothing", 16),
            kv(b, "zone", zoneName(drag.zone), 16),
            kv(b, "would dock", drag.willDock ? "yes" : "no", 16),
            specimen(b, "preview", dockHint(b, drag)),
        ]);
        body_ ~= spacer(b);
    }

    body_ ~= section(b, "what the container owns", [
        kv(b, "press owns the drag", "a grab keeps every motion (STM11)", 16,
            Slot.docs),
        kv(b, "wheel", "goes under the pointer, not to the focus", 16, Slot.docs),
        kv(b, "tab activation", "press arms, release over the SAME tab fires",
            16, Slot.docs),
        kv(b, "re-dock", "a tab that travels far enough moves its pane", 16,
            Slot.docs),
        kv(b, "restore", "unknown panes drop; a split of one collapses", 16,
            Slot.docs),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Every one of those is reachable from the keyboard as well: w/e/n/s "
        ~ "re-dock the focused pane against its neighbour, which is the same "
        ~ "pure layout-to-layout step the drop applies. A container whose "
        ~ "only route to a feature is a drag has nothing to offer a target "
        ~ "without a pointer.", w);

    return column(b, body_);
}

/// Renders one node of the arrangement by walking it — a split becomes a row
/// or column, a tabbed group its strip above the active pane, a leaf its
/// header above its content.
private uint renderNode(ref Builder b, in DockContainer c, uint idx)
{
    if (idx >= c.layout.nodes.length)
        return b.add(Widget(kind: WidgetKind.column));
    const n = c.layout.nodes[idx];
    if (!n.visible)
        return b.add(Widget(kind: WidgetKind.column));

    if (n.kind == DockKind.leaf)
        return paneBox(b, c, n.pane, n.title, n.extent);

    if (n.kind == DockKind.tabs)
    {
        // The strip is the shared component (`WGT23`), and the ids are the
        // container's own tab ids so a click resolves without a second map.
        string[] labels;
        size_t active;
        foreach (i, ch; n.children)
        {
            labels ~= c.layout.nodes[ch].title;
            if (i == n.active)
                active = labels.length - 1;
        }
        const strip = tabStrip(b, labels, active, 0);
        const shown = n.children[n.active < n.children.length ? n.active : 0];
        return b.add(Widget(
            kind: WidgetKind.column,
            children: [strip, renderNode(b, c, shown)],
            width: n.extent > 0 ? SizeSpec.fixed(n.extent) : SizeSpec.grow(),
        ));
    }

    uint[] kids;
    foreach (i, ch; n.children)
    {
        if (i)
            kids ~= dividerBar(b, n.axis);
        kids ~= renderNode(b, c, ch);
    }
    return b.add(Widget(
        kind: n.axis == DockAxis.horizontal ? WidgetKind.row : WidgetKind.column,
        children: kids,
        width: SizeSpec.grow(),
    ));
}

/// One pane: its reserved header row above its content.
private uint paneBox(ref Builder b, in DockContainer c, PaneId pane,
    string title, int extent)
{
    const focused = c.focused == pane;
    const header = b.add(Widget(
        kind: WidgetKind.text,
        text: title,
        slot: focused ? Slot.chromeAccent : Slot.gutter,
        textStyle: TextStyle(bold: focused),
    ));
    const bar = b.add(Widget(
        kind: WidgetKind.column,
        children: [header],
        slot: focused ? Slot.chromeFocused : Slot.chrome,
        paintBackground: true,
        width: SizeSpec.grow(),
        height: SizeSpec.fixed(1),
    ));
    const content = b.add(Widget(
        kind: WidgetKind.panel,
        children: [b.add(Widget(kind: WidgetKind.column, children: [
            label(b, extent > 0 ? text(extent, " cells") : "flexes",
                Slot.code),
            label(b, paneBlurb(pane), Slot.muted),
        ]))],
        slot: Slot.surface,
        width: SizeSpec.grow(),
        height: SizeSpec.grow(),
        paintBackground: true,
        clipX: true,
    ));
    return b.add(Widget(
        kind: WidgetKind.column,
        children: [bar, content],
        width: extent > 0 ? SizeSpec.fixed(extent) : SizeSpec.grow(),
        height: SizeSpec.fixed(dockRows - 1),
    ));
}

/// A divider, drawn as glyphs so it is visible on a target with no colour.
private uint dividerBar(ref Builder b, DockAxis axis)
{
    const vertical = axis == DockAxis.horizontal;
    auto cells = new uint[](vertical ? dockRows - 1 : 1);
    foreach (i; 0 .. cells.length)
        cells[i] = b.add(Widget(kind: WidgetKind.glyph,
            glyph: vertical ? '│' : '─', slot: Slot.border));
    return b.add(Widget(
        kind: vertical ? WidgetKind.column : WidgetKind.row,
        children: cells,
        width: vertical ? SizeSpec.fixed(1) : SizeSpec.grow(),
        height: vertical ? SizeSpec.fixed(dockRows - 1) : SizeSpec.fixed(1),
    ));
}

/// What each pane stands in for — a demo pane still has to be about
/// something, or the arrangement reads as three empty boxes.
private string paneBlurb(PaneId p)
{
    switch (p)
    {
        case sidePane:  return "a file tree, say";
        case docPane:   return "the thing being read";
        case notesPane: return "…and a second document";
        default:        return "";
    }
}

private string paneName(PaneId p)
{
    switch (p)
    {
        case sidePane:  return "explorer";
        case docPane:   return "document";
        case notesPane: return "notes";
        default:        return "none";
    }
}

private string zoneName(DockZone z)
{
    final switch (z) with (DockZone)
    {
        case none:   return "none";
        case center: return "center · stack";
        case north:  return "north · split above";
        case south:  return "south · split below";
        case west:   return "west · split left";
        case east:   return "east · split right";
    }
}

/// Keeps the container built and sized. The shell calls this each frame with
/// a mutable state, which is the only place a page may arrange anything.
void step(ref GalleryState s, int dtMs)
{
    ensure(s);
}

/// ditto
bool handleKey(ref GalleryState s, in KeyEvent k)
{
    ensure(s);
    const other = s.dock.focused == sidePane ? docPane : sidePane;
    switch (k.key)
    {
        case Key.char_:
            switch (k.ch)
            {
                case 'h', 'l':
                {
                    // The keyboard route to the divider, through the same
                    // clamped drag the pointer runs.
                    const node = s.dock.layout.nodeOf(sidePane);
                    auto ext = s.dock.layout.nodes[node].extent
                        + (k.ch == 'l' ? 2 : -2);
                    s.dock.layout.nodes[node].extent = ext;
                    ensure(s); // arrange re-clamps against the constraints
                    return true;
                }
                case '[', ']':
                {
                    // Tab switching without a pointer (DCK12).
                    const next = s.dock.focused == docPane ? notesPane : docPane;
                    s.dock.layout.activate(next);
                    s.dock.focused = next;
                    ensure(s);
                    return true;
                }
                case 'f':
                    s.dock.focusNext();
                    return true;
                case 'w', 'e', 'n', 's':
                {
                    // The same pure layout → layout step a drop applies, so
                    // re-docking is not a pointer-only feature.
                    const zone = k.ch == 'w' ? DockZone.west
                        : k.ch == 'e' ? DockZone.east
                            : k.ch == 'n' ? DockZone.north : DockZone.south;
                    s.dock.layout = s.dock.layout.redocked(
                        s.dock.focused, other, zone);
                    ensure(s);
                    return true;
                }
                case 'r':
                    s.dock.layout = demoLayout();
                    s.dock.focused = docPane;
                    ensure(s);
                    return true;
                default: return false;
            }
        default: return false;
    }
}

/// ditto
bool handlePointer(ref GalleryState s, in PointerEvent p, in WidgetTree tree,
    in Frame[] frames)
{
    ensure(s);
    const area = rectOf(tree, frames, hitDock);
    if (area.width <= 0)
        return false;
    // Translate into the container's own space before handing it over: the
    // container answers in the coordinates it was arranged in, and a page
    // that fed it screen positions would be asking a different question.
    PointerEvent q = p;
    q.pos = Point(p.pos.x - area.x, p.pos.y - area.y);
    const r = s.dock.handle(cast(const) Event(q));
    return r.kind != RouteKind.none;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui_gallery.pages.dockKeyboardReachesEveryInteraction")
@safe unittest
{
    // DCK12 in one test: every interaction this page offers has a keyboard
    // route, so the page is usable on a target with no pointer at all.
    GalleryState s;
    s.surface = Size(100, 40);
    ensure(s);
    const startPanes = s.dock.layout.panes().length;

    static KeyEvent ch(dchar c) => KeyEvent(Key.char_, c);

    // The divider, clamped by the sidebar's own minimum.
    const wide = s.dock.paneExtent(sidePane);
    assert(handleKey(s, ch('h')));
    assert(s.dock.paneExtent(sidePane) < wide);
    foreach (_; 0 .. 20)
        handleKey(s, ch('h'));
    assert(s.dock.paneExtent(sidePane) >= 8, "the minimum still holds");

    // Tabs, and focus.
    assert(handleKey(s, ch(']')));
    assert(s.dock.focused == notesPane);
    assert(handleKey(s, ch('f')));

    // Re-docking: the same transformation a drop applies, from a key.
    s.dock.focused = notesPane;
    assert(handleKey(s, ch('w')));
    assert(s.dock.layout.panes().length == startPanes, "no pane was lost");
    foreach (ref n; s.dock.layout.nodes)
        if (n.kind != DockKind.leaf)
            foreach (c; n.children)
                assert(c < s.dock.layout.nodes.length, "the arena stays sound");

    // And a way back, so a reader cannot strand themselves.
    assert(handleKey(s, ch('r')));
    assert(s.dock.layout.panes().length == startPanes);
    assert(s.dock.paneExtent(sidePane) == 18);
}

@("ui_gallery.pages.dockViewRendersEveryVisiblePane")
@safe unittest
{
    // The view walks the arrangement rather than hardcoding its shape, so a
    // re-dock changes what is drawn without the page knowing the new shape.
    GalleryState s;
    s.surface = Size(100, 40);
    ensure(s);

    static size_t panesDrawn(ref GalleryState s)
    {
        auto b = Builder();
        const root = view(b, s);
        auto tree = b.finish(root);
        // Count the pane bodies: every visible pane draws its blurb, and
        // an inactive tab's pane has no frame at all to draw one from.
        size_t n;
        foreach (ref node; tree.nodes)
            if (node.kind == WidgetKind.text
                && (node.text == "a file tree, say"
                    || node.text == "the thing being read"
                    || node.text == "…and a second document"))
                ++n;
        return n;
    }

    // Two panes show: the sidebar and the active tab (the inactive tab's
    // pane has no frame at all, which is the container's doing).
    assert(panesDrawn(s) == 2);

    // Re-dock notes beside the sidebar: three panes now show, because the
    // tabbed group is gone and nothing is hidden behind a tab.
    s.dock.focused = notesPane;
    handleKey(s, KeyEvent(Key.char_, 'w'));
    assert(panesDrawn(s) == 3);
}
