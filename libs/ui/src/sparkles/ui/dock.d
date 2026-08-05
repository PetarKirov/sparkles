/**
The docking container (`DCK1`–`DCK3`, `DCK6`–`DCK9`, `DCK13`): the pane
composition every host wrote by hand — where the panes are, which one has
focus, who owns the pointer, which divider a drag resizes, and where an
event goes — as one value with a pure interface.

Two halves, deliberately separable:

$(UL
$(LI $(LREF DockLayout) — the arrangement as $(B data): a flat arena
    (`WGT1`'s discipline) of splits and pane leaves, with per-leaf extent
    constraints and visibility. Regular, so it copies, compares and
    (`DCK2`) serializes; geometry is a pure function of it.)
$(LI $(LREF DockContainer) — the arrangement as $(B behavior): the STM8
    divider drags, the STM11 capture, focus with a deterministic order,
    and $(LREF DockContainer.handle), which answers $(I where does this
    event go) with a $(LREF Route) instead of calling into panes.)
)

Routing returns a value rather than dispatching, and that is the point:
the container decides policy (re-aim on press, click-to-focus, capture
freezing, wheel-under-pointer, coordinate translation) while the host
keeps its own pane types with no interface to implement and no callback
web to register. `DCK13`'s precedence — capture, then dividers, then the
positional query — lives in one readable function, testable with
scripted events and no window.

Tabbed groups (`DCK4`) and drag-to-redock (`DCK5`) extend the same arena
in `C-2b`/`C-2c`; the node kind is already a sum over roles so they add a
case rather than re-cutting the value.
*/
module sparkles.ui.dock;

import sparkles.base.term_control : PointerShape;
import sparkles.input.events : Event, match, PointerAction, PointerButton,
    PointerEvent, WheelEvent;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.state : CaptureState, SplitState;

@safe:

/// A pane's stable identity (`DCK1`): the application's own handle, so a
/// layout restore can drop ids it no longer knows (`DCK2`) without
/// disturbing the rest.
alias PaneId = uint;

/// Which way a split arranges its children.
enum DockAxis : ubyte
{
    horizontal, /// side by side; dividers are vertical rules
    vertical,   /// stacked; dividers are horizontal rules
}

/// What a node is. Tabbed groups (`DCK4`) join here at `C-2b`.
enum DockKind : ubyte
{
    leaf,  /// one pane
    split, /// an ordered row/column of children
}

/// One node of the layout arena.
struct DockNode
{
    DockKind kind;
    DockAxis axis;      /// `split` only
    uint[] children;    /// `split` only — indices into `DockLayout.nodes`
    PaneId pane;        /// `leaf` only
    /// Extent along the PARENT's axis. `0` flexes (shares the remainder
    /// with the other flexing siblings); non-zero is a fixed extent, the
    /// sidebar model every dock framework offers.
    int extent;
    int minExtent;      /// lower clamp for a divider drag
    int maxExtent;      /// upper clamp; `0` = unbounded
    bool visible = true;
}

/// The arrangement as data (`DCK1`).
struct DockLayout
{
    DockNode[] nodes;
    uint root;
    /// Divider thickness in the container's units — 1 cell in a terminal,
    /// 1 cell-width in hue's GPU host.
    int dividerExtent = 1;

    /**
    Deep-copies (`DCK1`). A flat arena is only a $(B value) if copying it
    copies the arena: with D's shallow slice copy, a "snapshot" would
    alias the original and mutating either would corrupt both — which is
    the difference between a layout you can restore (`DCK2`) and one you
    merely hold a second name for.
    */
    this(ref return scope const DockLayout other)
    {
        nodes.length = other.nodes.length;
        foreach (i, ref n; other.nodes)
            nodes[i] = DockNode(kind: n.kind, axis: n.axis,
                children: n.children.dup, pane: n.pane, extent: n.extent,
                minExtent: n.minExtent, maxExtent: n.maxExtent,
                visible: n.visible);
        root = other.root;
        dividerExtent = other.dividerExtent;
    }

    /// Appends a pane leaf and returns its node index.
    uint addLeaf(PaneId pane, int extent = 0, int minExtent = 0,
        int maxExtent = 0)
    {
        nodes ~= DockNode(kind: DockKind.leaf, pane: pane, extent: extent,
            minExtent: minExtent, maxExtent: maxExtent);
        return cast(uint)(nodes.length - 1);
    }

    /// Appends a split over already-added children and returns its index.
    uint addSplit(DockAxis axis, uint[] children, int extent = 0)
    {
        nodes ~= DockNode(kind: DockKind.split, axis: axis,
            children: children, extent: extent);
        return cast(uint)(nodes.length - 1);
    }

    /// The node holding `pane`, or `uint.max`.
    uint nodeOf(PaneId pane) const pure nothrow @nogc
    {
        foreach (i, ref n; nodes)
            if (n.kind == DockKind.leaf && n.pane == pane)
                return cast(uint) i;
        return uint.max;
    }

    /// Shows or hides a pane; a hidden pane takes no space and no divider.
    void setVisible(PaneId pane, bool visible) pure nothrow @nogc
    {
        const i = nodeOf(pane);
        if (i != uint.max)
            nodes[i].visible = visible;
    }

    /// ditto
    bool visible(PaneId pane) const pure nothrow @nogc
    {
        const i = nodeOf(pane);
        return i != uint.max && nodes[i].visible;
    }
}

/// A visible pane's computed rectangle.
struct PaneFrame
{
    PaneId pane;
    Rect rect;
}

/**
A divider between two adjacent visible children of a split — carrying not
just its rect but the drag range it permits, because the walk that places
it is exactly where both neighbours' constraints are known. A drag is then
a clamp against two integers instead of a re-derivation.
*/
struct DividerFrame
{
    uint node;       /// the split node
    uint beforeNode; /// the child node this divider follows
    uint afterNode;  /// the child node it precedes
    DockAxis axis;
    Rect rect;
    int start;       /// axis coordinate where `beforeNode`'s child begins
    int lo;          /// smallest axis position the divider may take
    int hi;          /// largest, honouring both neighbours' constraints
}

/**
Computes the frames (`DCK1` geometry): pure, so a layout's arrangement is
checkable without a canvas. Buffers are reused — the caller keeps them
across frames and pays no per-frame allocation after warm-up.
*/
void dockFrames(in DockLayout l, in Rect area, ref PaneFrame[] panes,
    ref DividerFrame[] dividers)
{
    panes.length = 0;
    dividers.length = 0;
    if (l.nodes.length && l.root < l.nodes.length)
        walk(l, l.root, area, panes, dividers);
}

private void walk(in DockLayout l, uint idx, in Rect area,
    ref PaneFrame[] panes, ref DividerFrame[] dividers)
{
    const n = l.nodes[idx];
    if (!n.visible)
        return;
    if (n.kind == DockKind.leaf)
    {
        panes ~= PaneFrame(n.pane, area);
        return;
    }

    // Visible children only: a hidden pane costs neither space nor divider.
    uint[] vis;
    foreach (c; n.children)
        if (l.nodes[c].visible)
            vis ~= c;
    if (!vis.length)
        return;

    const horiz = n.axis == DockAxis.horizontal;
    const total = horiz ? area.width : area.height;
    const gaps = cast(int)(vis.length - 1) * l.dividerExtent;

    // Fixed children take their extent; the rest share what is left. Sizing
    // is its own pass so the placing pass below knows every extent — which
    // is what lets a divider carry its own drag range.
    int fixed;
    int flexCount;
    foreach (c; vis)
    {
        if (l.nodes[c].extent > 0)
            fixed += l.nodes[c].extent;
        else
            ++flexCount;
    }
    int remaining = total - gaps - fixed;
    if (remaining < 0)
        remaining = 0;

    auto ext = new int[vis.length];
    foreach (i, c; vis)
    {
        ext[i] = l.nodes[c].extent;
        if (ext[i] <= 0)
        {
            // The last flexing child absorbs the rounding remainder, so the
            // children always tile the area exactly.
            ext[i] = flexCount > 1 ? remaining / flexCount : remaining;
            remaining -= ext[i];
            --flexCount;
        }
    }

    int pos = horiz ? area.x : area.y;
    foreach (i, c; vis)
    {
        const childArea = horiz
            ? Rect(pos, area.y, ext[i], area.height)
            : Rect(area.x, pos, area.width, ext[i]);
        walk(l, c, childArea, panes, dividers);
        const start = pos;
        pos += ext[i];
        if (i + 1 < vis.length)
        {
            // The drag redistributes between these two neighbours only:
            // each keeps its declared minimum (never below one unit), and a
            // bounded child keeps its maximum.
            const before = l.nodes[c];
            const after = l.nodes[vis[i + 1]];
            int lo = start + (before.minExtent > 1 ? before.minExtent : 1);
            int hi = start + ext[i] + ext[i + 1]
                - (after.minExtent > 1 ? after.minExtent : 1);
            if (before.maxExtent > 0 && start + before.maxExtent < hi)
                hi = start + before.maxExtent;
            if (hi < lo)
                hi = lo;
            dividers ~= DividerFrame(idx, c, vis[i + 1], n.axis, horiz
                    ? Rect(pos, area.y, l.dividerExtent, area.height)
                    : Rect(area.x, pos, area.width, l.dividerExtent),
                start, lo, hi);
            pos += l.dividerExtent;
        }
    }
}

/// What the container decided an event means (`DCK13`).
enum RouteKind : ubyte
{
    none,      /// nothing claimed it — the host's own global handling applies
    pane,      /// deliver `event` (pane-local coordinates) to `pane`
    container, /// the container consumed it (a divider drag)
}

/// One routing decision — a value, so routing is testable without panes.
struct Route
{
    RouteKind kind;
    PaneId pane;
    Event event;    /// translated into the target pane's coordinate space
    bool relayout;  /// geometry changed; the host re-arranges its panes
}

/**
The arrangement as behavior (`DCK3`, `DCK6`–`DCK9`, `DCK13`).

Holds the layout, the derived frames, and the interaction machines. The
host calls $(LREF arrange) when its surface resizes and $(LREF handle)
per event, then applies the returned $(LREF Route).
*/
struct DockContainer
{
    DockLayout layout;
    /// Derived by $(LREF arrange) — the host paints from these.
    PaneFrame[] paneFrames;
    /// ditto
    DividerFrame[] dividers;
    /// The focused pane (`DCK6`); click-to-focus and $(LREF focusNext)
    /// maintain it.
    PaneId focused;
    /// How far from a divider's rect a press still grabs it: `0` is the
    /// exact cell a terminal offers, a pixel host wants a few px either
    /// side. The divider is drawn thin and grabbed thick, as everywhere.
    int grabTolerance;

    private Rect area;
    private CaptureState capture;
    private SplitState drag;
    private uint dragDivider = uint.max;
    private uint hoverDivider = uint.max;
    private PaneId pointerPane;
    private bool havePointerPane;

    // Capture ids (STM11): panes and dividers must not collide, and `0`
    // means "free" to the machine, so both spaces start above it.
    private enum size_t paneCapBase = 1;
    private enum size_t divCapBase = size_t(1) << 32;

    /**
    Recomputes the frames for `area` (`DCK1`), re-clamping fixed extents
    against their constraints first — STM8's post-resize re-clamp,
    generalized: a sidebar sized for a wide window must not keep that
    width when the window shrinks under it.
    */
    void arrange(in Rect newArea)
    {
        area = newArea;
        foreach (ref n; layout.nodes)
        {
            if (n.extent <= 0)
                continue;
            if (n.minExtent > 0 && n.extent < n.minExtent)
                n.extent = n.minExtent;
            if (n.maxExtent > 0 && n.extent > n.maxExtent)
                n.extent = n.maxExtent;
        }
        dockFrames(layout, area, paneFrames, dividers);
    }

    /// The pane whose frame contains `p`, or `false` when none does.
    bool paneAt(in Point p, out PaneId pane) const pure nothrow @nogc
    {
        foreach (ref f; paneFrames)
            if (p.x >= f.rect.x && p.x < f.rect.x + f.rect.width
                && p.y >= f.rect.y && p.y < f.rect.y + f.rect.height)
            {
                pane = f.pane;
                return true;
            }
        return false;
    }

    /// The divider under `p` within $(LREF grabTolerance), or `uint.max`.
    uint dividerAt(in Point p) const pure nothrow @nogc
    {
        foreach (i, ref d; dividers)
        {
            const t = grabTolerance;
            const hit = d.axis == DockAxis.horizontal
                ? p.x >= d.rect.x - t && p.x < d.rect.x + d.rect.width + t
                    && p.y >= d.rect.y && p.y < d.rect.y + d.rect.height
                : p.y >= d.rect.y - t && p.y < d.rect.y + d.rect.height + t
                    && p.x >= d.rect.x && p.x < d.rect.x + d.rect.width;
            if (hit)
                return cast(uint) i;
        }
        return uint.max;
    }

    /// `true` while a divider drag owns the pointer.
    bool resizing() const pure nothrow @nogc => dragDivider != uint.max;

    /**
    Updates the hover chrome from a pointer position — frozen while
    something owns the pointer, so a drag never re-lights a divider it
    merely crosses. $(LREF handle) does this itself; a host that needs
    $(LREF shape) $(B before) routing — a terminal writing OSC 22 out of
    band does — calls it first, and the repeat is idempotent.
    */
    void hovered(in Point p) pure nothrow @nogc
    {
        if (capture.isFree)
            hoverDivider = dividerAt(p);
    }

    /**
    The one wanted pointer shape (`DCK9`). The pane shapes are supplied by
    the host — only it knows what its panes' contents want — split into
    the shape a live pane GRAB wants and the one a mere hover wants, so
    the established precedence holds exactly: any grab (divider or pane)
    outranks every hover.
    */
    PointerShape shape(PointerShape paneGrab = PointerShape.default_,
        PointerShape paneHover = PointerShape.default_) const
        pure nothrow @nogc
    {
        if (resizing)
            return dividerShape(dividers[dragDivider].axis);
        if (paneGrab != PointerShape.default_)
            return paneGrab;
        if (hoverDivider != uint.max)
            return dividerShape(dividers[hoverDivider].axis);
        return paneHover;
    }

    private static PointerShape dividerShape(DockAxis axis) pure nothrow @nogc
        => axis == DockAxis.horizontal
            ? PointerShape.ewResize : PointerShape.nsResize;

    /// Moves focus to the next (`+1`) or previous (`-1`) visible pane in
    /// layout order — the deterministic traversal `DCK6` asks for.
    void focusNext(int step = 1) pure nothrow @nogc
    {
        if (!paneFrames.length)
            return;
        size_t at;
        foreach (i, ref f; paneFrames)
            if (f.pane == focused)
            {
                at = i;
                break;
            }
        const n = paneFrames.length;
        const next = (at + n + (step >= 0 ? 1 : n - 1)) % n;
        focused = paneFrames[next].pane;
    }

    /**
    Routes one event (`DCK13`): a live capture first (a drag belongs to
    whoever took the press, wherever the pointer strays), then dividers,
    then the positional query; keys go to the focused pane, and a wheel
    goes to the pane under the pointer regardless of focus (`DCK7`).
    */
    Route handle(in Event e)
    {
        Route r;
        e.match!(
            (in PointerEvent p) { r = routePointer(p); },
            (in WheelEvent w) {
                // Under the pointer, regardless of focus (DCK7). Over
                // chrome (a divider) the position resolves to no pane, and
                // the focused one takes it — a wheel is never dropped.
                PaneId pane;
                if (!paneAt(w.pos, pane))
                {
                    if (!paneFrames.length)
                        return;
                    pane = focused;
                }
                WheelEvent q = w;
                q.pos = toLocal(w.pos, pane);
                r = Route(RouteKind.pane, pane, Event(q));
            },
            (_) {
                // Keys and everything else with no position of its own go
                // to the focused pane; the host decides globals first.
                if (paneFrames.length)
                    r = Route(RouteKind.pane, focused, e);
            });
        return r;
    }

    private Route routePointer(in PointerEvent p)
    {
        hovered(p.pos);

        // 1. A live divider drag owns everything until release (DCK3).
        if (resizing)
        {
            const d = dividers[dragDivider];
            if (p.action == PointerAction.release)
            {
                drag = drag.released();
                dragDivider = uint.max;
                capture = capture.released();
                return Route(RouteKind.container, 0, Event(p));
            }
            drag = drag.draggedTo(axisOf(d.axis, p.pos), d.lo, d.hi);
            // A drag redistributes between ITS TWO NEIGHBOURS — the same
            // pair the clamp range was derived from. The preceding child
            // takes the new extent; a fixed follower gives up exactly what
            // was taken (a flexing one absorbs it by definition), so no
            // third pane moves because two were resized.
            const was = axisOf(d.axis, Point(d.rect.x, d.rect.y)) - d.start;
            const now = drag.size - d.start;
            layout.nodes[d.beforeNode].extent = now;
            if (layout.nodes[d.afterNode].extent > 0)
                layout.nodes[d.afterNode].extent -= now - was;
            arrange(area);
            return Route(RouteKind.container, 0, Event(p), relayout: true);
        }

        // 2. A press on a divider starts a resize and takes the capture.
        if (p.action == PointerAction.press && p.button == PointerButton.left
            && capture.isFree)
        {
            const idx = dividerAt(p.pos);
            if (idx != uint.max)
            {
                const d = dividers[idx];
                dragDivider = idx;
                drag = SplitState(axisOf(d.axis, Point(d.rect.x, d.rect.y)))
                    .started(axisOf(d.axis, p.pos));
                capture = capture.capturedBy(divCapBase + idx);
                return Route(RouteKind.container, 0, Event(p));
            }
        }

        // 3. The positional query — re-aimed on a press, or whenever
        //    nothing owns the pointer; frozen mid-drag, which is the rule.
        if (p.action == PointerAction.press || capture.isFree)
        {
            PaneId under;
            if (paneAt(p.pos, under))
            {
                pointerPane = under;
                havePointerPane = true;
                if (p.action == PointerAction.press
                    && p.button == PointerButton.left)
                {
                    capture = capture.capturedBy(paneCapBase + under);
                    focused = under; // click-to-focus (DCK6)
                }
            }
            else if (capture.isFree)
                havePointerPane = false;
        }

        // Route BEFORE releasing: the release completes the gesture and
        // belongs to whoever owned it, not to whatever now sits under the
        // pointer.
        PaneId target;
        bool have;
        if (!capture.isFree && capture.owner >= paneCapBase
            && capture.owner < divCapBase)
        {
            target = cast(PaneId)(capture.owner - paneCapBase);
            have = true;
        }
        else if (havePointerPane)
        {
            target = pointerPane;
            have = true;
        }
        if (p.action == PointerAction.release)
            capture = capture.released();
        if (!have)
            return Route.init;

        PointerEvent q = p;
        q.pos = toLocal(p.pos, target);
        return Route(RouteKind.pane, target, Event(q));
    }

    /// The pane-local spelling of a container position.
    Point toLocal(in Point p, PaneId pane) const pure nothrow @nogc
    {
        foreach (ref f; paneFrames)
            if (f.pane == pane)
                return Point(p.x - f.rect.x, p.y - f.rect.y);
        return p;
    }

    // A position's coordinate along a divider's axis: the one place the
    // container turns 2-D into the 1-D space a split drag lives in.
    private static int axisOf(DockAxis axis, in Point p) pure nothrow @nogc
        => axis == DockAxis.horizontal ? p.x : p.y;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    // hue's workspace: a fixed-width sidebar left of a flexing document.
    private enum PaneId tree = 1, doc = 2;

    private DockContainer twoPane(int treeCols = 32)
    {
        DockContainer c;
        const t = c.layout.addLeaf(tree, extent: treeCols, minExtent: 12);
        const d = c.layout.addLeaf(doc);
        c.layout.root = c.layout.addSplit(DockAxis.horizontal, [t, d]);
        c.focused = doc;
        c.arrange(Rect(0, 0, 100, 40));
        return c;
    }
}

@("ui.dock.framesTileTheArea")
@safe unittest
{
    auto c = twoPane();
    assert(c.paneFrames.length == 2 && c.dividers.length == 1);
    assert(c.paneFrames[0] == PaneFrame(tree, Rect(0, 0, 32, 40)));
    // One divider column, then the document takes the exact remainder.
    assert(c.dividers[0].rect == Rect(32, 0, 1, 40));
    assert(c.paneFrames[1] == PaneFrame(doc, Rect(33, 0, 67, 40)));

    // A hidden pane costs neither space nor divider: the document is alone
    // and fills everything (hue's 'e' toggle).
    c.layout.setVisible(tree, false);
    c.arrange(Rect(0, 0, 100, 40));
    assert(c.dividers.length == 0);
    assert(c.paneFrames == [PaneFrame(doc, Rect(0, 0, 100, 40))]);
}

@("ui.dock.pointerRoutingAndCapture")
@safe unittest
{
    auto c = twoPane();

    // A press in the sidebar focuses it and routes pane-local (DCK6).
    auto r = c.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(5, 7))));
    assert(r.kind == RouteKind.pane && r.pane == tree);
    assert(c.focused == tree);
    r.event.match!((in PointerEvent p) { assert(p.pos == Point(5, 7)); },
        (_) { assert(false); });

    // The drag crosses into the document pane — and STAYS with the sidebar,
    // translated to ITS space: press owns the drag (STM11/DCK8).
    r = c.handle(Event(PointerEvent(action: PointerAction.drag,
        button: PointerButton.left, pos: Point(60, 7))));
    assert(r.kind == RouteKind.pane && r.pane == tree);

    // The release also belongs to the owner, and frees the pointer after.
    r = c.handle(Event(PointerEvent(action: PointerAction.release,
        button: PointerButton.left, pos: Point(60, 7))));
    assert(r.kind == RouteKind.pane && r.pane == tree);

    // Now that nothing owns it, a press in the document pane arrives
    // translated by the pane's origin.
    r = c.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(40, 3))));
    assert(r.kind == RouteKind.pane && r.pane == doc && c.focused == doc);
    r.event.match!((in PointerEvent p) { assert(p.pos == Point(7, 3)); },
        (_) { assert(false); });
}

@("ui.dock.wheelGoesUnderThePointer")
@safe unittest
{
    auto c = twoPane();
    c.focused = doc;
    // Focus is on the document, but the wheel is over the sidebar: it
    // scrolls the sidebar (DCK7 — a focused pane never swallows a wheel
    // spun elsewhere).
    const r = c.handle(Event(WheelEvent(dy: 1, pos: Point(4, 9))));
    assert(r.kind == RouteKind.pane && r.pane == tree);
    // Keys, having no position, go to the focused pane.
    const k = c.handle(Event(WheelEvent(dy: 1, pos: Point(70, 9))));
    assert(k.kind == RouteKind.pane && k.pane == doc);
}

@("ui.dock.dividerDragResizes")
@safe unittest
{
    auto c = twoPane();
    // A press on the divider column starts a resize; the container
    // consumes it rather than routing it to a pane (DCK3/DCK13).
    auto r = c.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(32, 5))));
    assert(r.kind == RouteKind.container && c.resizing);
    assert(c.shape() == PointerShape.ewResize);

    // Dragging moves the divider; the sidebar takes the new extent and the
    // flexing document absorbs the difference.
    r = c.handle(Event(PointerEvent(action: PointerAction.drag,
        button: PointerButton.left, pos: Point(50, 5))));
    assert(r.kind == RouteKind.container && r.relayout);
    assert(c.paneFrames[0].rect.width == 50);
    assert(c.paneFrames[1].rect == Rect(51, 0, 49, 40));

    // The declared minimum clamps it — a drag past the edge parks there.
    r = c.handle(Event(PointerEvent(action: PointerAction.drag,
        button: PointerButton.left, pos: Point(-40, 5))));
    assert(c.paneFrames[0].rect.width == 12);

    // Release ends the drag and frees the pointer for the panes again. The
    // shape stays a resize because the pointer is still ON the divider it
    // just dragged there — it changes when the pointer moves away.
    r = c.handle(Event(PointerEvent(action: PointerAction.release,
        button: PointerButton.left, pos: Point(12, 5))));
    assert(!c.resizing && c.shape() == PointerShape.ewResize);
    r = c.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(60, 5))));
    assert(r.kind == RouteKind.pane && r.pane == doc);
    assert(c.shape() == PointerShape.default_);
}

@("ui.dock.shapePrecedence")
@safe unittest
{
    auto c = twoPane();
    // Hovering the divider wants a resize shape…
    c.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(32, 5))));
    assert(c.shape() == PointerShape.ewResize);
    // …but a live PANE grab outranks that hover (DCK9), and a divider drag
    // outranks everything.
    assert(c.shape(PointerShape.nsResize) == PointerShape.nsResize);
    c.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(60, 5))));
    assert(c.shape() == PointerShape.default_);
    assert(c.shape(PointerShape.default_, PointerShape.text)
        == PointerShape.text);
}

@("ui.dock.focusTraversalIsDeterministic")
@safe unittest
{
    auto c = twoPane();
    c.focused = tree;
    c.focusNext();
    assert(c.focused == doc);
    c.focusNext();
    assert(c.focused == tree, "traversal wraps in layout order");
    c.focusNext(-1);
    assert(c.focused == doc);
}

@("ui.dock.verticalSplitsAndThreePanes")
@safe unittest
{
    // A stacked split of three, so both the axis generality and the
    // "a drag redistributes between its two neighbours only" rule are
    // exercised — hue itself only has one horizontal divider today.
    DockContainer c;
    const a = c.layout.addLeaf(1, extent: 10, minExtent: 3);
    const b = c.layout.addLeaf(2, extent: 10, minExtent: 3);
    const d = c.layout.addLeaf(3, minExtent: 3);
    c.layout.root = c.layout.addSplit(DockAxis.vertical, [a, b, d]);
    c.arrange(Rect(0, 0, 50, 40));

    assert(c.paneFrames[0].rect == Rect(0, 0, 50, 10));
    assert(c.paneFrames[1].rect == Rect(0, 11, 50, 10));
    assert(c.paneFrames[2].rect == Rect(0, 22, 50, 18));
    assert(c.dividers.length == 2);
    assert(c.dividers[1].axis == DockAxis.vertical);
    // A horizontal rule wants the vertical resize shape.
    c.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(20, 21))));
    assert(c.shape() == PointerShape.nsResize);

    // Dragging the FIRST divider down is bounded by the second pane's
    // minimum — the third pane is not a party to it and does not move.
    c.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(20, 10))));
    c.handle(Event(PointerEvent(action: PointerAction.drag,
        button: PointerButton.left, pos: Point(20, 39))));
    assert(c.paneFrames[0].rect.height == 17); // 10 + 10 − 3
    assert(c.paneFrames[2].rect == Rect(0, 22, 50, 18));
}

@("ui.dock.layoutIsRegular")
@safe unittest
{
    // DCK1: copy, compare — the precondition for DCK2's persistence and
    // for snapshotting an arrangement in a test.
    auto a = twoPane();
    auto b = a.layout;
    assert(b == a.layout);
    b.nodes[0].extent = 20;
    assert(b != a.layout);
    assert(a.layout.nodeOf(tree) == 0 && a.layout.nodeOf(99) == uint.max);
}
