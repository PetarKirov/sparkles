/**
The overlay layer (`docs/specs/ui/popup.md` `LYR1`–`LYR12`, `POP3`, `POP6`,
`POP7`): which nodes of a tree are overlays, the order they paint and are hit
in, and the frame-built arena a container routes against.

$(B An overlay is authored as a child of its anchor) (`POP3`). A
$(REF_ALTTEXT `WidgetKind.popup`, WidgetKind, sparkles,ui,widget) node that is not the tree's root is
one: layout takes it out of its parent's flow (`LYR7`) and places it against
the parent's rect with $(REF place, sparkles,ui,overlay,place); only its
$(I emission) moves — the display list and the hit walks visit it after the
flow, in band order, outside every ancestor's clip. There is no reparenting
and no portal, and a root `popup` is just a surface: there is nothing for it
to float out of.

$(B Openness is membership) (`LYR1`, `LYR9`). An overlay is open for a frame
because its node is in that frame's tree; no record carries a visible flag,
and a closed overlay is one the view stopped building. $(LREF eachOverlay) is
the one ordering every walk uses, so the display list, $(REF hoverTargets,
sparkles,ui,state), $(REF keyTargets, sparkles,ui,state) and
$(LREF overlayArena) cannot disagree about which overlay is on top.

$(B Order.) Bands paint in the order `adorn`, `popup`, `hint`, `notify`
(`LYR2`); within a band, overlays paint in tree order, which puts a nested
overlay after the one it was authored in. An overlay inside another takes the
higher of the two bands, so a child never sorts below its parent and every
record's parent is strictly earlier in the arena (`LYR4`). Hits go the other
way: the last target wins (`LYR1`). An overlay that is closing still paints
but takes no hits (`LYR10`), nor does anything nested in it.
*/
module sparkles.ui.overlay.arena;

import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.overlay.place : Adjust, Align, FlipRule, Side;
import sparkles.ui.widget : Visibility, WidgetKind, WidgetTree;

/**
The band an overlay paints in (`LYR2`, `LYR12`). The vocabulary is closed and
there is no integer priority: a caller names what an overlay $(I is), never
how far up it should go.
*/
enum OverlayBand : ubyte
{
    /// Adornments over the content: the dock's drop hint (`DCK5`). Never a
    /// dismissal parent, never focusable.
    adorn,
    /// Menus, dropdowns, context menus, dialogs: the only band in the
    /// dismissal stack.
    popup,
    /// Tooltips and hover cards: never a dismissal parent, never focusable.
    hint,
    /// Notifications (`WGT16`): visible and clickable over a modal overlay.
    notify,
}

/**
What a view declares about one overlay, on its node (`Widget.overlay`). Every
field is a value (`POP4`); the placement fields are $(REF PlaceRequest,
sparkles,ui,overlay,place)'s, and layout makes the request from them.
*/
struct OverlaySpec
{
    OverlayBand band = OverlayBand.popup; ///
    Side side = Side.bottom;              /// the side of the anchor asked for
    Align alignment = Align.start;        /// the gravity along the anchor's edge
    int gap;                              /// cells between the anchor and the overlay
    int shift;                            /// cells along the edge
    ubyte adjust = Adjust.standard;       /// which adjustments may fire
    FlipRule flipRule;                    ///
    /// Cover the anchor instead of sitting beside it: the overlay takes the
    /// anchor's rect exactly — an adornment such as the dock's drop hint.
    bool cover;
    /// Anchor to `anchor`, a rect in the parent's own cells (from its
    /// origin), instead of to the parent's whole rect.
    bool hasAnchor;
    /// ditto
    Rect anchor;
    /// The overlay is animating out (`LYR10`): it paints, and takes no hits.
    bool closing;
}

/// The most overlays one frame holds (`POP7`). An overlay past it is not in
/// the arena, is not painted and takes no hits; $(LREF OverlayArena.overflowed)
/// says it happened.
enum size_t maxOverlays = 16;

/// Whether node `idx` of `tree` is an overlay: a `popup` that is not the root.
bool floats(in WidgetTree tree, uint idx) @safe pure nothrow @nogc
    => idx != tree.root && idx < tree.nodes.length && tree.nodes[idx].kind == WidgetKind.popup;

/// Whether `tree` has any overlay at all — the walks' fast path.
bool hasOverlays(in WidgetTree tree) @safe pure nothrow @nogc
{
    foreach (i, ref n; tree.nodes)
        if (n.kind == WidgetKind.popup && i != tree.root)
            return true;
    return false;
}

/// "No enclosing overlay", as $(LREF eachOverlay) reports a parent.
enum uint noOverlay = uint.max;

/**
Calls `visit(idx, parent, closing)` for each open overlay of `tree`, as
`frames` laid it out, in paint order
(`LYR1`): band by band, in tree order within a band, at most
$(LREF maxOverlays) of them. `parent` is the node of the nearest enclosing
overlay, or $(LREF noOverlay); `closing` is whether this overlay or one it
is nested in is closing (`LYR10`). An overlay under a node that is not
visible is not open, nor is one whose anchor layout found scrolled out of
view (`Frame.overlayHidden`): either way its anchor is not drawn, and neither
is anything nested in it.

Every walk that visits overlays — the display list, the hit and key targets,
the arena — goes through this, so they agree on the order and on the cap.
*/
void eachOverlay(alias visit, F)(in WidgetTree tree, in F[] frames)
{
    if (!tree.nodes.length || !hasOverlays(tree))
        return;
    size_t count;
    foreach (band; OverlayBand.min .. OverlayBand.max + 1)
    {
        void walk(uint idx, int enclosing, uint parent, bool closing)
        {
            foreach (ci; tree.nodes[idx].children)
            {
                ref const child = tree.nodes[ci];
                if (child.visibility != Visibility.visible)
                    continue;
                if (floats(tree, ci))
                {
                    if (frames[ci].overlayHidden)
                        continue;
                    const own = cast(int) child.overlay.band;
                    const eff = own > enclosing ? own : enclosing;
                    const shut = closing || child.overlay.closing;
                    if (eff == band && count < maxOverlays)
                    {
                        ++count;
                        visit(ci, parent, shut);
                    }
                    walk(ci, eff, ci, shut);
                }
                else
                    walk(ci, enclosing, parent, closing);
            }
        }
        walk(tree.root, -1, noOverlay, false);
    }
}

/// How many overlays `tree` has open, cap or no cap.
private size_t openOverlays(F)(in WidgetTree tree, in F[] frames)
{
    if (!tree.nodes.length || !hasOverlays(tree))
        return 0;
    size_t count;
    void walk(uint idx)
    {
        foreach (ci; tree.nodes[idx].children)
        {
            if (tree.nodes[ci].visibility != Visibility.visible)
                continue;
            if (floats(tree, ci))
            {
                if (frames[ci].overlayHidden)
                    continue;
                ++count;
            }
            walk(ci);
        }
    }
    walk(tree.root);
    return count;
}

/**
A handle on one overlay of one frame (`LYR3`): its slot in the arena and the
arena's generation. A handle from an earlier frame names a generation the
arena no longer has, so it is told apart from a live one rather than silently
naming whatever overlay took its slot. `gen == 0` is no overlay.
*/
struct OverlayId
{
    uint slot; ///
    uint gen;  ///

    /// Whether this names an overlay at all.
    bool opCast(T : bool)() const @safe pure nothrow @nogc => gen != 0;
}

/// One open overlay of a frame.
struct OverlayRecord
{
    OverlayId id;             ///
    uint node;                /// its node in the frame's tree
    /// The record of the nearest enclosing overlay — always earlier in the
    /// arena (`LYR4`) — or `-1`.
    int parent = -1;
    OverlayBand band;         /// the band it paints in: its own, or its parent's if higher
    Rect rect;                /// where layout placed it
    bool closing;             /// animating out: paints, takes no hits (`LYR10`)
    size_t key;               /// its node's `Widget.key`, for finding it next frame
}

/**
The overlays one frame has open, in paint order (`LYR1`): index order is paint
order, and hit order is the reverse. Built from a laid-out tree by
$(LREF overlayArena); a container keeps the last painted frame's and routes
against it (`LYR5`). Bounded (`POP7`): no allocation, ever.
*/
struct OverlayArena
{
    private OverlayRecord[maxOverlays] store;
    private uint count;
    uint gen = 1;    /// this frame's generation (`LYR3`)
    bool overflowed; /// the tree declared more than `maxOverlays` open overlays

@safe pure nothrow @nogc:

    /// The records, in paint order.
    inout(OverlayRecord)[] opSlice() inout return => store[0 .. count];

    /// How many overlays are open.
    size_t length() const => count;

    /// Whether `id` names an overlay of this frame.
    bool isOpen(OverlayId id) const => id.gen != 0 && id.gen == gen && id.slot < count;

    /// The record `id` names; `id` must be open.
    ref const(OverlayRecord) opIndex(OverlayId id) const return
    in (isOpen(id), "a stale or empty overlay handle")
        => store[id.slot];

    /// The overlay keyed `key` this frame, or no overlay.
    OverlayId idOf(size_t key) const
    {
        if (key != 0)
            foreach (ref r; store[0 .. count])
                if (r.key == key)
                    return r.id;
        return OverlayId.init;
    }

    /// The overlay at node `node` this frame, or no overlay.
    OverlayId idOfNode(uint node) const
    {
        foreach (ref r; store[0 .. count])
            if (r.node == node)
                return r.id;
        return OverlayId.init;
    }

    /// Whether `candidate` is `ancestor` or nested in it (`LYR4`): a walk up
    /// the parent links, which only ever point earlier.
    bool isWithin(OverlayId ancestor, OverlayId candidate) const
    {
        if (!isOpen(ancestor) || !isOpen(candidate))
            return false;
        for (int i = cast(int) candidate.slot; i >= 0; i = store[i].parent)
            if (i == cast(int) ancestor.slot)
                return true;
        return false;
    }

    /// The topmost open overlay in `band`, or no overlay.
    OverlayId topmost(OverlayBand band) const
    {
        foreach_reverse (ref r; store[0 .. count])
            if (r.band == band)
                return r.id;
        return OverlayId.init;
    }

    /**
    The topmost overlay under `p` that takes hits, or no overlay — the
    top-layers rung of the routing precedence (`LYR5`, `DCK13`): front to
    back, so a point an overlay covers is its overlay's however far the
    overlay strayed from the pane it was authored in. A closing overlay is
    passed over (`LYR10`).
    */
    OverlayId at(Point p) const
    {
        foreach_reverse (ref r; store[0 .. count])
            if (!r.closing && r.rect.contains(p))
                return r.id;
        return OverlayId.init;
    }
}

/**
The arena of the overlays `tree` has open, as `frames` laid them out: the
records in paint order, each with its parent, band and rect. `gen` is the
frame's generation; a host counting frames passes its count, so a handle kept
from an earlier frame reads as stale.
*/
OverlayArena overlayArena(F)(in WidgetTree tree, in F[] frames, uint gen = 1)
if (__traits(compiles, (in F f) { Rect r = f.rect; }))
in (frames.length == tree.nodes.length, "frames must be the layout of exactly this tree")
{
    OverlayArena a;
    a.gen = gen == 0 ? 1 : gen;
    eachOverlay!((uint idx, uint parent, bool closing) {
        int p = -1;
        if (parent != noOverlay)
            foreach (k, ref r; a.store[0 .. a.count])
                if (r.node == parent)
                    p = cast(int) k;
        assert(parent == noOverlay || p >= 0, "a parent is always earlier (LYR4)");
        const own = tree.nodes[idx].overlay.band;
        const band = p >= 0 && a.store[p].band > own ? a.store[p].band : own;
        a.store[a.count] = OverlayRecord(OverlayId(a.count, a.gen), idx, p, band,
            frames[idx].rect, closing, tree.nodes[idx].key);
        ++a.count;
    })(tree, frames);
    a.overflowed = openOverlays(tree, frames) > a.count;
    return a;
}

// ---------------------------------------------------------------------------
// Tests: the overlay layer end to end — layout, paint, hits, the arena.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.ui.widget : Builder, Widget;

    // A column of `rows` one-cell rows, the second of which carries `over`
    // as an overlay child; `clipRows` > 0 makes the column a viewport that
    // tall, inside a ten-row surface. Returns the tree; the anchor row is
    // node `anchorOut`.
    private WidgetTree anchoredTree(ref Builder b, uint[] over, out uint anchorOut,
        int rows = 4, int clipRows = 0, int scroll = 0) @safe
    {
        import sparkles.ui.geometry : SizeSpec;
        uint[] col;
        foreach (i; 0 .. rows)
        {
            uint[] kids = [b.add(Widget(kind: WidgetKind.text, text: "row"))];
            if (i == 1)
                kids ~= over;
            const r = b.add(Widget(kind: WidgetKind.row, children: kids, hitId: 100 + i));
            if (i == 1)
                anchorOut = r;
            col ~= r;
        }
        if (!clipRows)
            return b.finish(b.add(Widget(kind: WidgetKind.column, children: col,
                width: SizeSpec.fixed(40))));
        const viewport = b.add(Widget(kind: WidgetKind.column, children: col,
            width: SizeSpec.fixed(40), height: SizeSpec.fixed(clipRows), clipY: true,
            childOffset: Point(0, scroll)));
        return b.finish(b.add(Widget(kind: WidgetKind.column, children: [viewport],
            width: SizeSpec.fixed(40), height: SizeSpec.fixed(10))));
    }

    private uint popupOf(ref Builder b, string text, OverlaySpec spec = OverlaySpec.init,
        size_t hit = 0, size_t key = 0) @safe
        => b.add(Widget(kind: WidgetKind.popup, overlay: spec, hitId: hit, key: key,
            children: [b.add(Widget(kind: WidgetKind.text, text: text))]));
}

/// An overlay leaves its parent's flow (`LYR7`) and hangs off the parent's
/// rect (`POP3`): the rows below it do not move, and it sits under its anchor.
@("overlay.arena.outOfFlowAndAnchored")
@safe unittest
{
    import sparkles.ui.layout : layout;

    auto b = Builder();
    uint anchor;
    const pop = popupOf(b, "menu item");
    auto tree = anchoredTree(b, [pop], anchor);
    const frames = layout(tree);

    auto plain = Builder();
    uint plainAnchor;
    auto bare = anchoredTree(plain, [], plainAnchor);
    const bareFrames = layout(bare);
    foreach (i; 0 .. tree.nodes[tree.root].children.length)
        assert(frames[tree.nodes[tree.root].children[i]].rect
            == bareFrames[bare.nodes[bare.root].children[i]].rect, "the flow is untouched");
    assert(frames[anchor].rect.width == 3, "the anchor does not grow to hold it");
    assert(frames[pop].rect == Rect(0, 2, 9, 1), "below its anchor, at the anchor's start");
}

/// An overlay escapes every ancestor's clip, in paint and in hits (`LYR5`,
/// `LYR8`): it paints after the flow, outside the viewport's scissor, and its
/// target is whole and last, so it wins the point it covers.
@("overlay.arena.escapesTheClipItWasAuthoredIn")
@safe unittest
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : hitAt, hoverTargets;
    import sparkles.ui.style : defaultTwoslashPalette, Slot;

    auto b = Builder();
    uint anchor;
    const pop = b.add(Widget(kind: WidgetKind.popup, slot: Slot.surface, paintBackground: true,
        hitId: 7, children: [b.add(Widget(kind: WidgetKind.text, text: "a\nb\nc"))]));
    // A two-row viewport: the anchor is its second row, the popup hangs three
    // rows below it — past the viewport's bottom.
    auto tree = anchoredTree(b, [pop], anchor, rows: 4, clipRows: 2);
    const frames = layout(tree);
    assert(frames[pop].rect == Rect(0, 2, 1, 3));

    const ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));
    size_t fill = size_t.max, popClip = size_t.max;
    foreach (i, ref op; ops)
    {
        if (op.kind == OpKind.popClip)
            popClip = i;
        if (op.kind == OpKind.fillRect && op.rect == frames[pop].rect)
            fill = i;
    }
    assert(fill != size_t.max && popClip != size_t.max && fill > popClip,
        "painted after the viewport's scissor is popped");

    const targets = hoverTargets(tree, frames);
    assert(targets[$ - 1].hitId == 7 && targets[$ - 1].rect == frames[pop].rect,
        "the last target, unclipped");
    assert(hitAt(targets, 0.5f, 2.5f) == 7, "over the row it covers, it wins");
    assert(hitAt(targets, 2.5f, 2.5f) == 0, "past its edge, the clipped row is not hit");
}

/// Bands order the arena whatever the tree order, a nested overlay takes the
/// higher band and follows its parent, and the parent link only points back
/// (`LYR1`, `LYR2`, `LYR4`).
@("overlay.arena.bandsOrderAndParents")
@safe unittest
{
    import sparkles.ui.layout : layout;

    auto b = Builder();
    const inner = popupOf(b, "inner", OverlaySpec(band: OverlayBand.adorn), key: 3);
    const note = b.add(Widget(kind: WidgetKind.popup, key: 2,
        overlay: OverlaySpec(band: OverlayBand.notify),
        children: [b.add(Widget(kind: WidgetKind.text, text: "note")), inner]));
    const tip = popupOf(b, "tip", OverlaySpec(band: OverlayBand.hint), key: 1);
    const menu = popupOf(b, "menu", OverlaySpec(band: OverlayBand.popup), key: 4);
    uint anchor;
    auto tree = anchoredTree(b, [note, tip, menu], anchor);
    const a = overlayArena(tree, layout(tree));

    assert(a.length == 4);
    assert(a[][0].node == menu && a[][1].node == tip && a[][2].node == note
        && a[][3].node == inner, "popup, hint, notify; the nested one after its parent");
    assert(a[][3].band == OverlayBand.notify, "an adorn inside a notify paints as a notify");
    assert(a[][3].parent == 2 && a[][2].parent == -1);
    assert(a.isWithin(a.idOf(2), a.idOf(3)) && !a.isWithin(a.idOf(3), a.idOf(2)));
    assert(a.topmost(OverlayBand.hint) == a.idOf(1));
    assert(!a.topmost(OverlayBand.adorn), "nothing paints in adorn");
}

/// A handle is generational (`LYR3`): one kept from an earlier frame is stale,
/// not a name for whatever overlay took its slot.
@("overlay.arena.handlesGoStale")
@safe unittest
{
    import sparkles.ui.layout : layout;

    auto b = Builder();
    uint anchor;
    auto tree = anchoredTree(b, [popupOf(b, "x", key: 9)], anchor);
    const frames = layout(tree);
    const first = overlayArena(tree, frames, gen: 1);
    const id = first.idOf(9);
    assert(first.isOpen(id) && first[id].key == 9);
    const next = overlayArena(tree, frames, gen: 2);
    assert(!next.isOpen(id), "last frame's handle");
    assert(next.isOpen(next.idOf(9)) && next.idOf(9).slot == id.slot);
}

/// Open is membership (`LYR9`): an overlay the view hid, or one under a hidden
/// node, is not in the arena and paints nothing.
@("overlay.arena.openIsMembership")
@safe unittest
{
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Visibility;

    auto b = Builder();
    const hidden = b.add(Widget(kind: WidgetKind.popup, visibility: Visibility.collapsed,
        children: [b.add(Widget(kind: WidgetKind.text, text: "gone"))]));
    const under = b.add(Widget(kind: WidgetKind.box, visibility: Visibility.hidden,
        children: [popupOf(b, "under a hidden node")]));
    uint anchor;
    auto tree = anchoredTree(b, [hidden, under], anchor);
    assert(overlayArena(tree, layout(tree)).length == 0);
}

/// An overlay whose anchor scrolled out of its viewport is not open: it does
/// not slide into view over content it does not belong to.
@("overlay.arena.anchorScrolledAwayIsNotOpen")
@safe unittest
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : hoverTargets;
    import sparkles.ui.style : defaultTwoslashPalette, Slot;

    foreach (scroll; [0, 3])
    {
        auto b = Builder();
        uint anchor;
        const pop = b.add(Widget(kind: WidgetKind.popup, slot: Slot.surface,
            paintBackground: true, hitId: 7,
            children: [b.add(Widget(kind: WidgetKind.text, text: "menu"))]));
        auto tree = anchoredTree(b, [pop], anchor, rows: 6, clipRows: 2, scroll: scroll);
        const frames = layout(tree);
        const open = scroll == 0;
        assert(frames[pop].overlayHidden == !open);
        assert(overlayArena(tree, frames).length == (open ? 1 : 0));
        bool hit;
        foreach (t; hoverTargets(tree, frames))
            hit |= t.hitId == 7;
        assert(hit == open);
        const ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
            RgbColor(0, 0, 0), RgbColor(255, 255, 255));
        bool painted;
        foreach (ref op; ops)
            painted |= op.rect == frames[pop].rect && !op.rect.empty;
        assert(painted == open);
    }
}

/// An overlay that is closing still paints, and neither it nor anything
/// nested in it takes a hit (`LYR10`).
@("overlay.arena.closingPaintsButTakesNoHits")
@safe unittest
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : hoverTargets, keyTargets;
    import sparkles.ui.style : defaultTwoslashPalette, Slot;

    auto b = Builder();
    const nested = popupOf(b, "sub", hit: 6, key: 6);
    const closing = b.add(Widget(kind: WidgetKind.popup, slot: Slot.surface, paintBackground: true,
        hitId: 5, key: 5, overlay: OverlaySpec(closing: true),
        children: [b.add(Widget(kind: WidgetKind.text, text: "fading")), nested]));
    uint anchor;
    auto tree = anchoredTree(b, [closing], anchor);
    const frames = layout(tree);

    const ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));
    bool painted;
    foreach (ref op; ops)
        painted |= op.kind == OpKind.fillRect && op.rect == frames[closing].rect;
    assert(painted, "it still paints");
    foreach (t; hoverTargets(tree, frames))
        assert(t.hitId != 5 && t.hitId != 6, "no hit for it or its child");
    foreach (t; keyTargets(tree, frames))
        assert(t.key != 5 && t.key != 6);
    const a = overlayArena(tree, frames);
    assert(a.length == 2 && a[][1].closing, "the nested one is closing with it");
    assert(!a.at(frames[closing].rect.origin), "the routing rung passes it over");
}

/// The arena is bounded (`POP7`): past `maxOverlays`, overlays are dropped
/// from it — and from paint and hits, which walk the same order — and the
/// arena says so.
@("overlay.arena.boundedCapacity")
@safe unittest
{
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : hoverTargets;

    auto b = Builder();
    uint[] many;
    foreach (i; 0 .. maxOverlays + 3)
        many ~= popupOf(b, "o", hit: 1000 + i);
    uint anchor;
    auto tree = anchoredTree(b, many, anchor);
    const frames = layout(tree);
    const a = overlayArena(tree, frames);
    assert(a.length == maxOverlays && a.overflowed);
    size_t overlayTargets;
    foreach (t; hoverTargets(tree, frames))
        overlayTargets += t.hitId >= 1000;
    assert(overlayTargets == maxOverlays);
}

/// The routing rung (`LYR5`): `at` answers front to back, so where two
/// overlays overlap the later one takes the point.
@("overlay.arena.atIsFrontToBack")
@safe unittest
{
    import sparkles.ui.geometry : Point;
    import sparkles.ui.layout : layout;

    auto b = Builder();
    const under = popupOf(b, "underneath", key: 1);
    const over = popupOf(b, "over", OverlaySpec(band: OverlayBand.hint), key: 2);
    uint anchor;
    auto tree = anchoredTree(b, [over, under], anchor);
    const a = overlayArena(tree, layout(tree));
    assert(a.at(Point(1, 2)) == a.idOf(2), "the hint is on top where they overlap");
    assert(a.at(Point(7, 2)) == a.idOf(1), "past the hint, the popup");
    assert(!a.at(Point(30, 0)));
}

/// The arrow follows the placement (`PLC10`): on the edge facing the anchor, at
/// the anchor's cell — and on the other edge once the overlay flips.
@("overlay.arena.arrowFollowsThePlacement")
@safe unittest
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Insets, SizeSpec;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : BorderStyle, Decoration, defaultTwoslashPalette, Slot;

    foreach (anchorRow; [1, 4])
    {
        auto b = Builder();
        const pop = b.add(Widget(kind: WidgetKind.popup, slot: Slot.surface,
            decoration: Decoration(borderWidth: Insets.all(1), borderStyle: BorderStyle.solid,
                arrow: true),
            overlay: OverlaySpec(alignment: Align.center, hasAnchor: true,
                anchor: Rect(2, 0, 1, 1)),
            children: [b.add(Widget(kind: WidgetKind.text, text: "abcdefgh"))]));
        // A five-row surface; the anchor is a row near the top, or the last one.
        uint[] col;
        uint anchor;
        foreach (i; 0 .. 5)
        {
            uint[] kids = [b.add(Widget(kind: WidgetKind.text, text: "row"))];
            if (i == anchorRow)
                kids ~= pop;
            const r = b.add(Widget(kind: WidgetKind.row, children: kids));
            if (i == anchorRow)
                anchor = r;
            col ~= r;
        }
        auto tree = b.finish(b.add(Widget(kind: WidgetKind.column, children: col,
            width: SizeSpec.fixed(20))));
        const frames = layout(tree);
        const ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
            RgbColor(0, 0, 0), RgbColor(255, 255, 255));
        bool seen;
        foreach (ref op; ops)
            if (op.kind == OpKind.fillRect && op.rect == frames[pop].rect)
            {
                seen = true;
                const v = op.visual;
                assert(v.arrow && v.arrowOffset == 2, "at the anchor's column");
                assert(v.arrowEdge == (anchorRow == 1 ? Side.top : Side.bottom),
                    "facing the anchor, above or below");
            }
        assert(seen);
    }
}
