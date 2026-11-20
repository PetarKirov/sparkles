/**
The Overlays page (`POP8`): the anchored-overlay layer, exercised where it
earns its keep — a dropdown that hangs out of the pane it was written in.

The files pane is narrow; its actions menu is wider and hangs over the
divider into the preview. Layout places the menu against its button and
paints it above both panes. The page reports the painted menu to the dock as
a top layer, so the click that lands on the part over the preview still goes
to the files pane, whose menu it is. Without that, the dock would find the
pane by its rect and hand the click to the preview.
*/
module pages.overlays_page;

import sparkles.input : Event, Point, PointerAction, PointerButton, PointerEvent;
import sparkles.ui.components.dock : DockAxis, DockContainer, DockKind, DockLayout,
    PaneId, RouteKind, TopLayer;
import sparkles.ui.geometry : Insets, Rect, SizeSpec;
import sparkles.ui.hit_ids : HitKey;
import sparkles.ui.layout : Frame;
import sparkles.ui.overlay : Align, OverlayBand, overlayArena, OverlaySpec, Side;
import sparkles.ui.state : hitAt, hoverTargets;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import kit;
import scrollbars : rectOf;
import state : GalleryState, hitOf;

@safe:

/// The demo's panes.
enum PaneId filesPane = 1, previewPane = 2;

/// The demo's height in cells, and the files pane's width: narrower than the
/// menu, which is the point.
enum int demoRows = 8, filesCols = 14;

/// The menu's items, in order.
immutable string[] menuItems = ["rename", "duplicate", "move to trash"];

/// The demo area's hit key — its origin, as on the Dock page — and the menu
/// items' block (`INP27`).
enum HitKey areaKey = HitKey("gallery.overlays.area");
/// ditto
enum HitKey menuKey = HitKey("gallery.overlays.menu");
/// ditto — the menu's own key, which finds its record in the arena.
enum size_t menuNodeKey = 0x0E_7A_11;

/// The page's `claimHits` hook.
void claimHits(ref GalleryState s) pure nothrow @nogc
{
    s.hits.block(areaKey);
    s.hits.block(menuKey, menuItems.length);
}

private DockLayout demoLayout()
{
    DockLayout l;
    const f = l.addLeaf(filesPane, extent: filesCols, minExtent: 8);
    const p = l.addLeaf(previewPane);
    l.root = l.addSplit(DockAxis.horizontal, [f, p]);
    return l;
}

private void ensure(ref GalleryState s)
{
    if (!s.overlayDock.layout.nodes.length)
        s.overlayDock.layout = demoLayout();
    s.overlayDock.arrange(Rect(0, 0, s.contentWidth, demoRows));
}

/// The view: total over a default state, like every page.
uint view(ref Builder b, in GalleryState s)
{
    if (s.overlayDock.layout.nodes.length)
        return viewWith(b, s.overlayDock, s);
    DockContainer fresh;
    fresh.layout = demoLayout();
    fresh.arrange(Rect(0, 0, s.contentWidth, demoRows));
    return viewWith(b, fresh, s);
}

private uint viewWith(ref Builder b, in DockContainer c, in GalleryState s)
{
    const w = s.contentWidth;

    uint[] body_;
    body_ ~= heading(b, "Overlays · anchored, out of flow, on top");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "A popup is written as a child of what it hangs off. Layout takes it "
        ~ "out of its parent's flow and places it against the parent; the "
        ~ "display list paints it after everything else, outside every clip "
        ~ "it was written inside; and the hit list puts it last, so it wins "
        ~ "the cells it covers.", w);
    body_ ~= spacer(b);

    // The two panes, side by side, under one hit id at the container's origin;
    // the files pane as wide as the arrangement says (a divider drag moves it).
    int filesExtent = filesCols;
    foreach (ref n; c.layout.nodes)
        if (n.kind == DockKind.leaf && n.pane == filesPane && n.extent > 0)
            filesExtent = n.extent;
    uint[] panes = [
        filesBox(b, s, filesExtent),
        divider(b),
        previewBox(b),
    ];
    const arrangement = b.add(Widget(kind: WidgetKind.row, children: panes,
        width: SizeSpec.grow(), height: SizeSpec.fixed(demoRows),
        hitId: s.hitOf(areaKey)));
    body_ ~= section(b, "a menu wider than its pane", [arrangement]);
    body_ ~= spacer(b);

    const clicked = s.overlayClickPane == filesPane ? "the files pane"
        : s.overlayClickPane == previewPane ? "the preview pane" : "nothing yet";
    body_ ~= section(b, "the last click", [
        kv(b, "went to", clicked, 16, Slot.chromeAccent),
        kv(b, "item", s.overlayClickItem < menuItems.length
            ? menuItems[s.overlayClickItem] : "—", 16),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "the bands, bottom to top", [
        kv(b, "adorn", "decoration over content: the dock's drop hint", 16, Slot.docs),
        kv(b, "popup", "menus, dropdowns, dialogs; the dismissal stack", 16, Slot.docs),
        kv(b, "hint", "tooltips and hover cards", 16, Slot.docs),
        kv(b, "notify", "notifications, clickable over a modal", 16, Slot.docs),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "The dock finds a pane by its rect, so the part of the menu over the "
        ~ "preview would be the preview's. This page tells the dock where the "
        ~ "menu painted; the dock tests that first, and the click goes to the "
        ~ "files pane.", w);

    return b.add(Widget(kind: WidgetKind.column, children: body_));
}

private uint filesBox(ref Builder b, in GalleryState s, int extent)
{
    uint[] items;
    foreach (i, item; menuItems)
        items ~= b.add(Widget(kind: WidgetKind.text, text: item, slot: Slot.code,
            width: SizeSpec.grow(), hitId: s.hitOf(menuKey, i)));
    const menu = b.add(Widget(
        kind: WidgetKind.popup,
        children: [b.add(Widget(kind: WidgetKind.column, children: items,
            width: SizeSpec.grow()))],
        slot: Slot.surface,
        paintBackground: true,
        padding: Insets.all(1),
        width: SizeSpec.fixed(22),
        decoration: Decoration(borderWidth: Insets.all(1), borderStyle: BorderStyle.solid,
            borderSlot: Slot.border, borderRadius: 4, shadow: true, arrow: true),
        overlay: OverlaySpec(band: OverlayBand.popup, side: Side.bottom,
            alignment: Align.start),
        key: menuNodeKey,
    ));
    const button = b.add(Widget(kind: WidgetKind.row, children: [
        label(b, "▾ actions", Slot.chromeAccent), menu]));
    return b.add(Widget(
        kind: WidgetKind.panel,
        children: [b.add(Widget(kind: WidgetKind.column, children: [
            label(b, "files", Slot.gutter, TextStyle(bold: true)),
            button,
        ]))],
        slot: Slot.surface,
        paintBackground: true,
        clipX: true,
        width: SizeSpec.fixed(extent > 0 ? extent : filesCols),
        height: SizeSpec.fixed(demoRows),
    ));
}

private uint previewBox(ref Builder b)
    => b.add(Widget(
        kind: WidgetKind.panel,
        children: [b.add(Widget(kind: WidgetKind.column, children: [
            label(b, "preview", Slot.gutter, TextStyle(bold: true)),
            label(b, "the neighbouring pane", Slot.muted),
        ]))],
        slot: Slot.surfaceBase,
        width: SizeSpec.grow(),
        height: SizeSpec.fixed(demoRows),
    ));

private uint divider(ref Builder b)
{
    auto cells = new uint[](demoRows);
    foreach (ref c; cells)
        c = b.add(Widget(kind: WidgetKind.glyph, glyph: '│', slot: Slot.border));
    return b.add(Widget(kind: WidgetKind.column, children: cells));
}

/**
A pointer event over the demo: the page reports the menu the last frame
painted to the dock as a top layer (`LYR5`), lets the dock route the event,
and records where a completed click went and which item it hit.
*/
bool handlePointer(ref GalleryState s, in PointerEvent p, in WidgetTree tree,
    in Frame[] frames)
{
    ensure(s);
    const area = rectOf(tree, frames, s.hitOf(areaKey));
    if (area.width <= 0 || !area.contains(p.pos))
        return false;

    // The host's half of the rung: where its panes' overlays painted, in the
    // container's cells. The menu is the files pane's.
    const arena = overlayArena(tree, frames);
    TopLayer[1] layers;
    size_t n;
    const menu = arena.idOf(menuNodeKey);
    if (menu)
    {
        const r = arena[menu].rect;
        layers[n++] = TopLayer(filesPane, Rect(r.x - area.x, r.y - area.y, r.width, r.height));
    }
    s.overlayDock.paintedTopLayers(layers[0 .. n]);

    PointerEvent q = p;
    q.pos = Point(p.pos.x - area.x, p.pos.y - area.y);
    const r = s.overlayDock.handle(cast(const) Event(q));
    if (r.kind != RouteKind.pane)
        return r.kind != RouteKind.none;
    if (p.action == PointerAction.release && p.button == PointerButton.left)
    {
        s.overlayClickPane = r.pane;
        s.overlayClickItem = size_t.max;
        if (r.pane == filesPane)
        {
            const hit = hitAt(hoverTargets(tree, frames), p.pos.x + 0.5f, p.pos.y + 0.5f);
            foreach (i, item; menuItems)
                if (hit != 0 && hit == s.hitOf(menuKey, i))
                    s.overlayClickItem = i;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The page's whole point, asserted on its own tree: the menu hangs past the
/// files pane, and a click on that part reaches the files pane and its item.
@("ui_gallery.pages.overlaysMenuTakesTheClickPastItsPane")
@safe unittest
{
    import sparkles.ui.geometry : Constraints, Size;
    import sparkles.ui.layout : layout;

    GalleryState s;
    s.surface = Size(100, 40);
    claimHits(s);
    ensure(s);
    auto b = Builder();
    auto tree = b.finish(view(b, s));
    const frames = layout(tree, Constraints(maxW: s.contentWidth));

    const area = rectOf(tree, frames, s.hitOf(areaKey));
    const item = rectOf(tree, frames, s.hitOf(menuKey, 1));
    import std.conv : text;
    assert(item.x + item.width > area.x + filesCols + 1, text("the menu hangs past the divider: ",
        item, " in ", area, " at width ", s.contentWidth));

    const at = Point(area.x + filesCols + 3, item.y);
    PointerEvent press = PointerEvent(action: PointerAction.press, button: PointerButton.left,
        pos: at);
    PointerEvent release = press;
    release.action = PointerAction.release;
    assert(handlePointer(s, press, tree, frames));
    assert(handlePointer(s, release, tree, frames));
    assert(s.overlayClickPane == filesPane, "the menu's pane, not the one under it");
    assert(s.overlayClickItem == 1, "duplicate");

    // Below the menu, the preview is the preview's.
    const below = Point(area.x + filesCols + 3, area.y + demoRows - 1);
    press.pos = below;
    release.pos = below;
    handlePointer(s, press, tree, frames);
    handlePointer(s, release, tree, frames);
    assert(s.overlayClickPane == previewPane && s.overlayClickItem == size_t.max);
}
