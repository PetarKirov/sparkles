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
import sparkles.ui.state : CaptureState, PressState, SplitState;

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
    tabs,  /// a stack of panes, one shown, selected by a tab strip
}

/// One node of the layout arena.
struct DockNode
{
    DockKind kind;
    DockAxis axis;      /// `split` only
    uint[] children;    /// `split`/`tabs` — indices into `DockLayout.nodes`
    uint active;        /// `tabs` only — which child is shown
    PaneId pane;        /// `leaf` only
    /// `tabs` children only: the tab's width in the strip. `0` shares the
    /// strip equally — an application that measures its labels sets this
    /// so tabs are as wide as what they say.
    int tabExtent;
    /// Extent along the PARENT's axis. `0` flexes (shares the remainder
    /// with the other flexing siblings); non-zero is a fixed extent, the
    /// sidebar model every dock framework offers.
    int extent;
    int minExtent;      /// lower clamp for a divider drag
    int maxExtent;      /// upper clamp; `0` = unbounded
    bool visible = true;
    /// `leaf` only: rows reserved at the pane's top for its header
    /// (`DCK10`). `0` = no header, which is how a pane opts out.
    int headerExtent;
    /// `leaf` only: what the header says (`DCK11`). The container places
    /// and focuses the bar; the application still supplies the words,
    /// because only it knows them.
    string title;
    string headerCenter;
    string headerTrailing;
}

/// The arrangement as data (`DCK1`).
struct DockLayout
{
    DockNode[] nodes;
    uint root;
    /// Divider thickness in the container's units — 1 cell in a terminal,
    /// 1 cell-width in hue's GPU host.
    int dividerExtent = 1;
    /// The height of a tabbed group's strip, in the same units.
    int tabStripExtent = 1;

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
        {
            // Field by field through `tupleof`, not by naming them: a
            // hand-written list of a dozen fields silently loses the next
            // one somebody adds, which is how this constructor had already
            // stopped copying `tabStripExtent`. Only the mutable slice
            // needs duplicating — `string` is immutable, so sharing it IS
            // value semantics.
            DockNode m;
            static foreach (j; 0 .. DockNode.tupleof.length)
            {
                static if (is(typeof(DockNode.tupleof[j]) == uint[]))
                    m.tupleof[j] = n.tupleof[j].dup;
                else
                    m.tupleof[j] = n.tupleof[j];
            }
            nodes[i] = m;
        }
        root = other.root;
        dividerExtent = other.dividerExtent;
        tabStripExtent = other.tabStripExtent;
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

    /// Appends a tabbed group over already-added children (`DCK4`) and
    /// returns its index. The first child is shown until a tab is picked.
    uint addTabs(uint[] children, int extent = 0)
    {
        nodes ~= DockNode(kind: DockKind.tabs, children: children,
            extent: extent);
        return cast(uint)(nodes.length - 1);
    }

    /// Shows `pane`'s tab within its group, if it is in one.
    void activate(PaneId pane) pure nothrow @nogc
    {
        const leaf = nodeOf(pane);
        if (leaf == uint.max)
            return;
        foreach (ref n; nodes)
            if (n.kind == DockKind.tabs)
                foreach (i, c; n.children)
                    if (c == leaf)
                    {
                        n.active = cast(uint) i;
                        return;
                    }
    }

    /**
    This layout with every pane the caller does not know dropped
    (`DCK2`).

    The restore half of persistence: a saved arrangement names panes by
    id, and the application that reads it back may no longer offer all of
    them — a document closed, a tool pane removed by a later version. The
    spec's requirement is that such a layout $(B degrades) rather than
    failing, and degrading correctly is not a filter: dropping a leaf
    leaves its parent with one child (a split of one is not a split) or
    none (a group of nothing is not a group), and a tabbed group may lose
    the very child its `active` index pointed at.

    So this rebuilds rather than edits: surviving leaves keep their
    extents and constraints, a container that keeps one child is REPLACED
    by that child, a container that keeps none dies with it, and `active`
    is remapped to the survivors. An empty result means nothing was
    recognised, which is the caller's cue to use its default layout —
    reported as data rather than thrown.

    Serialization itself is deliberately absent: `sparkles:ui` may not
    depend on `sparkles:wired` (`PKG2`), and it does not need to — the
    arena is plain data, so the application that owns a config file also
    owns its encoding. What cannot live out there is this reconciliation,
    which needs to know what a split means.
    */
    DockLayout reconciled(scope const(PaneId)[] known) const
    {
        static bool isKnown(PaneId p, scope const(PaneId)[] known)
        {
            foreach (k; known)
                if (k == p)
                    return true;
            return false;
        }

        DockLayout r;
        r.dividerExtent = dividerExtent;
        r.tabStripExtent = tabStripExtent;
        if (!nodes.length || root >= nodes.length)
            return r;

        // Returns the surviving node's index in `r`, or `uint.max`.
        uint copy(uint idx)
        {
            const n = nodes[idx];
            if (n.kind == DockKind.leaf)
            {
                if (!isKnown(n.pane, known))
                    return uint.max;
                r.nodes ~= DockNode(kind: DockKind.leaf, pane: n.pane,
                    tabExtent: n.tabExtent, extent: n.extent,
                    minExtent: n.minExtent, maxExtent: n.maxExtent,
                    visible: n.visible, headerExtent: n.headerExtent,
                    title: n.title, headerCenter: n.headerCenter,
                    headerTrailing: n.headerTrailing);
                return cast(uint)(r.nodes.length - 1);
            }

            uint[] kids;
            uint active;
            bool haveActive;
            foreach (i, c; n.children)
            {
                const kept = copy(c);
                if (kept == uint.max)
                    continue;
                // The active tab follows its child; if that child is gone,
                // the first survivor takes over rather than the index
                // pointing into a shorter list.
                if (i == n.active && !haveActive)
                {
                    active = cast(uint)(kids.length);
                    haveActive = true;
                }
                kids ~= kept;
            }
            if (!kids.length)
                return uint.max;
            if (kids.length == 1)
            {
                // A container of one is not a container. The survivor
                // inherits the container's own share of its parent, or
                // keeps its own when the container merely flexed.
                if (n.extent > 0)
                    r.nodes[kids[0]].extent = n.extent;
                return kids[0];
            }
            r.nodes ~= DockNode(kind: n.kind, axis: n.axis, children: kids,
                active: haveActive ? active : 0, extent: n.extent,
                minExtent: n.minExtent, maxExtent: n.maxExtent,
                visible: n.visible);
            return cast(uint)(r.nodes.length - 1);
        }

        const kept = copy(root);
        if (kept == uint.max)
            return DockLayout.init; // nothing recognised: use your default
        r.root = kept;
        return r;
    }

    /**
    `moved` re-docked against `target` in `zone` (`DCK5`) — a pure
    `layout → layout` step, so a drop is checkable without a pointer.

    Stacking makes the target a tabbed group (or joins the one it is
    already in) with the moved pane active, because a reader who just
    dropped something wants to see it. A directional drop splits the
    target along the matching axis, with `moved` before or after it.

    Removing the moved pane first is what makes this total: its old
    parent may collapse, and that collapse can be the target's own
    ancestor. Reusing $(LREF reconciled) for the removal means the
    collapse rules are stated once rather than twice — and the target is
    looked up AFTERWARDS, in the rebuilt arena, so a stale index cannot
    survive the move.

    A no-op is returned unchanged: dropping a pane onto itself, onto a
    pane it already sits beside in that direction's degenerate case, or
    with an unknown id, all leave the layout alone rather than producing a
    subtly different one.
    */
    DockLayout redocked(PaneId moved, PaneId target, DockZone zone) const
    {
        if (zone == DockZone.none || moved == target)
            return DockLayout(this);
        if (nodeOf(moved) == uint.max || nodeOf(target) == uint.max)
            return DockLayout(this);

        // The moved pane's own leaf, kept so its extent/constraints and
        // header survive the trip.
        const src = nodes[nodeOf(moved)];

        // Take it out first: its parent may collapse, possibly above the
        // target. `reconciled` already knows those rules.
        PaneId[] keep;
        foreach (p; panes())
            if (p != moved)
                keep ~= p;
        auto r = reconciled(keep);
        if (!r.nodes.length)
            return DockLayout(this); // nothing left to dock against

        const t = r.nodeOf(target);
        if (t == uint.max)
            return DockLayout(this);

        // Re-add the moved leaf into the rebuilt arena. Field by field
        // through `tupleof` for the same reason the copy constructor does:
        // a named list would lose the next field somebody adds.
        DockNode m;
        static foreach (j; 0 .. DockNode.tupleof.length)
        {
            static if (is(typeof(DockNode.tupleof[j]) == uint[]))
                m.tupleof[j] = null; // a leaf has no children
            else
                m.tupleof[j] = src.tupleof[j];
        }
        r.nodes ~= m;
        const leaf = cast(uint)(r.nodes.length - 1);

        uint replacement;
        if (zone == DockZone.center)
        {
            // Join the target's group if it is already tabbed; otherwise
            // the target becomes one.
            uint owner = uint.max;
            foreach (i, ref n; r.nodes)
                if (n.kind == DockKind.tabs)
                    foreach (c; n.children)
                        if (c == t)
                            owner = cast(uint) i;
            if (owner != uint.max)
            {
                r.nodes[owner].children ~= leaf;
                r.nodes[owner].active =
                    cast(uint)(r.nodes[owner].children.length - 1);
                return r;
            }
            r.nodes ~= DockNode(kind: DockKind.tabs, children: [t, leaf],
                active: 1, extent: r.nodes[t].extent);
            replacement = cast(uint)(r.nodes.length - 1);
            // The target keeps its own share only through the group now.
            r.nodes[t].extent = 0;
        }
        else
        {
            const vertical = zone == DockZone.north || zone == DockZone.south;
            const before = zone == DockZone.north || zone == DockZone.west;
            uint[] kids = before ? [leaf, t] : [t, leaf];
            r.nodes ~= DockNode(kind: DockKind.split,
                axis: vertical ? DockAxis.vertical : DockAxis.horizontal,
                children: kids, extent: r.nodes[t].extent);
            replacement = cast(uint)(r.nodes.length - 1);
            // The new container takes the target's share of the parent;
            // inside it, both children flex unless the moved one was fixed.
            r.nodes[t].extent = 0;
        }

        // Hook the replacement where the target used to hang — skipping
        // the replacement itself, which legitimately holds `t` as a child.
        // Rewriting that one too made the node its own parent, and the
        // walk recursed until the stack ran out.
        if (r.root == t)
            r.root = replacement;
        else
            foreach (i, ref n; r.nodes)
            {
                if (i == replacement || n.kind == DockKind.leaf)
                    continue;
                foreach (ref c; n.children)
                    if (c == t)
                        c = replacement;
            }
        return r;
    }

    /// The pane ids this layout names, in arena order — what a caller
    /// compares against the panes it can actually offer.
    PaneId[] panes() const
    {
        PaneId[] ps;
        foreach (ref n; nodes)
            if (n.kind == DockKind.leaf)
                ps ~= n.pane;
        return ps;
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
One tab in a group's strip (`DCK4`). The strip is laid out once, by the
same walk that places the pane below it, and BOTH the paint and the hit
test read these frames — which is what makes the `IXR27` defect (a band
hit-tested by one geometry and painted by another) unrepresentable here.
The application paints the label; the container never learns it.
*/
struct TabFrame
{
    uint node;    /// the tabs node
    uint child;   /// index into that node's `children`
    PaneId pane;
    Rect rect;
    bool active;  /// this tab's pane is the one showing
}

/**
A pane's header strip (`DCK10`): the rect the container reserved at the
top of the pane, plus what goes in it and whether it should read focused.

The host paints it through the shared `headerBar` component; it does not
decide WHERE, because the same walk that placed the pane placed this —
which is what stops a header and its pane disagreeing about which rows
belong to whom.
*/
struct HeaderFrame
{
    PaneId pane;
    Rect rect;
    string title;
    string center;
    string trailing;
    bool focused;
}

/**
One arrangement's derived geometry, owned together (`PRN1`).

Panes, dividers, tabs and headers are not four unrelated buffers: they are
one answer to "where is everything this frame", and every one of them is
invalidated by the same event. Owning them as a value keeps that true by
construction, and gives the next kind of frame — a redock hint — a home
that does not lengthen anybody's parameter list.
*/
struct DockFrames
{
    PaneFrame[] panes;
    DividerFrame[] dividers;
    TabFrame[] tabs;
    HeaderFrame[] headers;
}

/**
Computes the frames (`DCK1` geometry): pure, so a layout's arrangement is
checkable without a canvas. Buffers are reused — the caller keeps them
across frames and pays no per-frame allocation after warm-up.
*/
void dockFrames(in DockLayout l, in Rect area, ref DockFrames f,
    PaneId focused = 0)
{
    f.panes.length = 0;
    f.dividers.length = 0;
    f.tabs.length = 0;
    f.headers.length = 0;
    if (l.nodes.length && l.root < l.nodes.length)
        walk(l, l.root, area, f, focused);
}

private void walk(in DockLayout l, uint idx, in Rect area,
    ref DockFrames f, PaneId focused)
{
    const n = l.nodes[idx];
    if (!n.visible)
        return;
    if (n.kind == DockKind.leaf)
    {
        // A pane's header is reserved from its own area (DCK10), so the
        // content rect a host paints into already excludes it — the row
        // cannot be claimed twice, and a pane that wants no header simply
        // leaves `headerExtent` at zero.
        Rect content = area;
        if (n.headerExtent > 0 && area.height > n.headerExtent)
        {
            f.headers ~= HeaderFrame(n.pane,
                Rect(area.x, area.y, area.width, n.headerExtent),
                n.title, n.headerCenter, n.headerTrailing,
                n.pane == focused);
            content = Rect(area.x, area.y + n.headerExtent, area.width,
                area.height - n.headerExtent);
        }
        f.panes ~= PaneFrame(n.pane, content);
        return;
    }
    if (n.kind == DockKind.tabs)
    {
        walkTabs(l, idx, area, f, focused);
        return;
    }

    // Visible children only: a hidden pane costs neither space nor divider.
    // Stack buffers, because a GPU host re-arranges every frame and a
    // container that allocated per split would be a per-frame allocation
    // in the steady state ([`NFR2`](feature-requirements)). A split wider
    // than the buffer falls back to the heap rather than truncating.
    enum stackChildren = 32;
    uint[stackChildren] visBuf;
    int[stackChildren] extBuf;
    uint[] visHeap;
    int[] extHeap;
    size_t nvis;
    foreach (c; n.children)
    {
        if (!l.nodes[c].visible)
            continue;
        if (nvis < stackChildren)
            visBuf[nvis] = c;
        else
        {
            if (!visHeap.length)
                visHeap = visBuf[].dup;
            visHeap ~= c;
        }
        ++nvis;
    }
    if (!nvis)
        return;
    uint[] vis = visHeap.length ? visHeap : visBuf[0 .. nvis];
    if (visHeap.length)
        extHeap = new int[nvis];
    int[] ext = extHeap.length ? extHeap : extBuf[0 .. nvis];

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
        walk(l, c, childArea, f, focused);
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
            f.dividers ~= DividerFrame(idx, c, vis[i + 1], n.axis, horiz
                    ? Rect(pos, area.y, l.dividerExtent, area.height)
                    : Rect(area.x, pos, area.width, l.dividerExtent),
                start, lo, hi);
            pos += l.dividerExtent;
        }
    }
}

// A tabbed group: a strip of tabs across the top, the active child below.
// Only the active child is walked, so an inactive pane has no frame at all
// — it cannot be hit, scrolled or painted by accident.
private void walkTabs(in DockLayout l, uint idx, in Rect area,
    ref DockFrames f, PaneId focused)
{
    const n = l.nodes[idx];
    const strip = l.tabStripExtent;

    int fixed;
    int flexCount;
    size_t nvis;
    foreach (c; n.children)
    {
        if (!l.nodes[c].visible)
            continue;
        ++nvis;
        if (l.nodes[c].tabExtent > 0)
            fixed += l.nodes[c].tabExtent;
        else
            ++flexCount;
    }
    if (!nvis)
        return;

    int remaining = area.width - fixed;
    if (remaining < 0)
        remaining = 0;
    int x = area.x;
    uint activeChild = uint.max;
    foreach (i, c; n.children)
    {
        if (!l.nodes[c].visible)
            continue;
        int w = l.nodes[c].tabExtent;
        if (w <= 0)
        {
            w = flexCount > 1 ? remaining / flexCount : remaining;
            remaining -= w;
            --flexCount;
        }
        const isActive = i == n.active;
        if (isActive)
            activeChild = c;
        f.tabs ~= TabFrame(idx, cast(uint) i, l.nodes[c].pane,
            Rect(x, area.y, w, strip), isActive);
        x += w;
    }

    // An `active` index pointing at a hidden or absent child would leave
    // the group blank; fall back to the first visible tab instead.
    if (activeChild == uint.max)
        foreach (c; n.children)
            if (l.nodes[c].visible)
            {
                activeChild = c;
                break;
            }
    if (activeChild == uint.max)
        return;
    walk(l, activeChild, Rect(area.x, area.y + strip, area.width,
        area.height - strip > 0 ? area.height - strip : 0), f, focused);
}

/// Where a dragged pane would land relative to a target pane (`DCK5`).
enum DockZone : ubyte
{
    none,   /// not over a droppable target
    center, /// stack into the target — it becomes (or joins) a tabbed group
    north,  /// split the target, dropping above it
    south,  /// …below
    west,   /// …left
    east,   /// …right
}

/**
The hint zone a position falls in, within `rect` (`DCK5`).

Edge bands take a fixed fraction of the target and the middle is the
stack zone, which is the arrangement every dock framework converged on
because it is predictable under a moving pointer: bands do not resize as
the pointer travels, so the hint does not flicker between two answers
near a boundary. Pure, so the zone a drag would drop into is testable
without dragging anything.
*/
DockZone dockZoneAt(in Rect rect, in Point p, int bandPercent = 25)
    @safe pure nothrow @nogc
{
    if (rect.width <= 0 || rect.height <= 0)
        return DockZone.none;
    if (p.x < rect.x || p.x >= rect.x + rect.width
        || p.y < rect.y || p.y >= rect.y + rect.height)
        return DockZone.none;
    const bw = rect.width * bandPercent / 100;
    const bh = rect.height * bandPercent / 100;
    const dx = p.x - rect.x, dy = p.y - rect.y;
    const fromRight = rect.width - 1 - dx, fromBottom = rect.height - 1 - dy;
    // Nearest edge wins, so a corner resolves to one zone rather than to
    // whichever test happened to run first.
    const minEdge = () {
        int m = dx;
        if (dy < m) m = dy;
        if (fromRight < m) m = fromRight;
        if (fromBottom < m) m = fromBottom;
        return m;
    }();
    if (bw <= 0 || bh <= 0)
        return DockZone.center;
    if (dx == minEdge && dx < bw)
        return DockZone.west;
    if (fromRight == minEdge && fromRight < bw)
        return DockZone.east;
    if (dy == minEdge && dy < bh)
        return DockZone.north;
    if (fromBottom == minEdge && fromBottom < bh)
        return DockZone.south;
    return DockZone.center;
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
    /// Derived by $(LREF arrange) — the host paints from these. Owned as
    /// one value because they are one answer, invalidated together.
    DockFrames frames;

    /// The pane content rects. (Named accessors over $(LREF frames), so a
    /// host reads the part it needs without spelling the whole.)
    ref inout(PaneFrame[]) paneFrames() inout return @safe pure nothrow @nogc
        => frames.panes;
    /// ditto
    ref inout(DividerFrame[]) dividers() inout return @safe pure nothrow @nogc
        => frames.dividers;
    /// ditto — the tab strips (`DCK4`); the host paints labels into these
    /// and the container hit-tests the same rects.
    ref inout(TabFrame[]) tabs() inout return @safe pure nothrow @nogc
        => frames.tabs;
    /// ditto — the reserved header strips (`DCK10`).
    ref inout(HeaderFrame[]) headers() inout return @safe pure nothrow @nogc
        => frames.headers;
    /// The focused pane (`DCK6`); click-to-focus and $(LREF focusNext)
    /// maintain it.
    PaneId focused;
    /// How far from a divider's rect a press still grabs it: `0` is the
    /// exact cell a terminal offers, a pixel host wants a few px either
    /// side. The divider is drawn thin and grabbed thick, as everywhere.
    int grabTolerance;

    private Rect area;
    private CaptureState capture;
    private PressState tabPress;
    private SplitState drag;
    private uint dragDivider = uint.max;
    private uint hoverDivider = uint.max;
    private PaneId pointerPane;
    private bool havePointerPane;

    // Capture ids (STM11): panes and dividers must not collide, and `0`
    // means "free" to the machine, so both spaces start above it.
    private enum size_t paneCapBase = 1;
    private enum size_t divCapBase = size_t(1) << 32;
    private enum size_t tabCapBase = size_t(1) << 48;

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
        dockFrames(layout, area, frames, focused);
    }

    /// A pane's laid-out extent along its split's axis, or `0` when it is
    /// hidden — the arrangement's answer to "how wide is the sidebar".
    int paneExtent(PaneId pane) const pure nothrow @nogc
    {
        foreach (ref f; paneFrames)
            if (f.pane == pane)
                return layout.nodes[layout.nodeOf(pane)].kind == DockKind.leaf
                    && isVerticalStack(pane) ? f.rect.height : f.rect.width;
        return 0;
    }

    /// A pane's origin along its split's axis (`0` when hidden), so a host
    /// can place content without re-deriving the tiling.
    int paneOrigin(PaneId pane) const pure nothrow @nogc
    {
        foreach (ref f; paneFrames)
            if (f.pane == pane)
                return isVerticalStack(pane) ? f.rect.y : f.rect.x;
        return 0;
    }

    private bool isVerticalStack(PaneId pane) const pure nothrow @nogc
    {
        const leaf = layout.nodeOf(pane);
        foreach (ref n; layout.nodes)
            if (n.kind == DockKind.split)
                foreach (c; n.children)
                    if (c == leaf)
                        return n.axis == DockAxis.vertical;
        return false;
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

    /// The tab under `p`, or `uint.max` — the same frames the host paints.
    uint tabAt(in Point p) const pure nothrow @nogc
    {
        foreach (i, ref t; tabs)
            if (p.x >= t.rect.x && p.x < t.rect.x + t.rect.width
                && p.y >= t.rect.y && p.y < t.rect.y + t.rect.height)
                return cast(uint) i;
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

        // 3. A tab strip is chrome over the pane below it, so it is tested
        //    before the positional query. Press ARMS the tab, a release
        //    over the SAME tab activates it (STM10) — a press that slides
        //    off cancels, which an `if (clicked && inRect)` never does.
        {
            const idx = tabAt(p.pos);
            const id = idx == uint.max ? 0 : tabCapBase + idx;
            if (p.action == PointerAction.press
                && p.button == PointerButton.left && idx != uint.max)
            {
                tabPress = tabPress.pressed(id);
                capture = capture.capturedBy(id);
                return Route(RouteKind.container, tabs[idx].pane, Event(p));
            }
            if (p.action == PointerAction.release && tabPress.armed != 0)
            {
                tabPress = tabPress.released(id);
                capture = capture.released();
                if (tabPress.activated != 0)
                {
                    const t = tabs[cast(size_t)(tabPress.activated - tabCapBase)];
                    layout.nodes[t.node].active = t.child;
                    focused = t.pane; // showing a pane gives it the keyboard
                    arrange(area);
                    tabPress = tabPress.cancelled();
                    return Route(RouteKind.container, t.pane, Event(p),
                        relayout: true);
                }
                return Route(RouteKind.container, 0, Event(p));
            }
            if (!capture.isFree && capture.owner >= tabCapBase)
                return Route(RouteKind.container, 0, Event(p));
        }

        // 4. The positional query — re-aimed on a press, or whenever
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

    /**
    The cell of `pane`'s CONTENT a position lands on, if any (`DCK11`).

    The one place a host converts a pointer into a pane's own row and
    column. It answers `false` outside that pane's content — including
    over its header strip, which belongs to the chrome and not to the
    content beneath it — so a caller cannot accidentally treat a click on
    a title bar as a click on the first row.

    Hosts computed this themselves, each subtracting its own idea of how
    many rows the chrome above had taken; that arithmetic is what made a
    hit rect drift from the paint it was supposed to match, and it is
    invisible to a screenshot because a mis-placed hit rect renders
    exactly like a correct one.
    */
    bool contentCell(in Point p, PaneId pane, out Point local)
        const pure nothrow @nogc
    {
        foreach (ref f; paneFrames)
            if (f.pane == pane)
            {
                if (p.x < f.rect.x || p.x >= f.rect.x + f.rect.width
                    || p.y < f.rect.y || p.y >= f.rect.y + f.rect.height)
                    return false;
                local = Point(p.x - f.rect.x, p.y - f.rect.y);
                return true;
            }
        return false;
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

@("ui.dock.tabbedGroupShowsOneAndActivatesOnRelease")
@safe unittest
{
    // A sidebar beside a tabbed group of two documents — hue's set, in
    // the shape C-2b gives it.
    enum PaneId side = 1, docA = 2, docB = 3;
    DockContainer c;
    const s = c.layout.addLeaf(side, extent: 20, minExtent: 10);
    const a = c.layout.addLeaf(docA);
    const b = c.layout.addLeaf(docB);
    const g = c.layout.addTabs([a, b]);
    c.layout.root = c.layout.addSplit(DockAxis.horizontal, [s, g]);
    c.arrange(Rect(0, 0, 100, 40));

    // Only the active pane has a frame: an inactive tab's pane cannot be
    // hit, scrolled or painted, because it does not exist this frame.
    assert(c.paneFrames.length == 2);
    assert(c.paneFrames[1] == PaneFrame(docA, Rect(21, 1, 79, 39)));
    assert(c.tabs.length == 2);
    assert(c.tabs[0] == TabFrame(g, 0, docA, Rect(21, 0, 39, 1), true));
    assert(c.tabs[1] == TabFrame(g, 1, docB, Rect(60, 0, 40, 1), false));

    // Press arms the second tab; the pane below has NOT changed yet.
    auto r = c.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(70, 0))));
    assert(r.kind == RouteKind.container && r.pane == docB);
    assert(c.paneFrames[1].pane == docA, "arming is not activating");

    // Release over the SAME tab activates it, and showing a pane focuses it.
    r = c.handle(Event(PointerEvent(action: PointerAction.release,
        button: PointerButton.left, pos: Point(70, 0))));
    assert(r.kind == RouteKind.container && r.relayout);
    assert(c.paneFrames[1].pane == docB);
    assert(c.focused == docB);
    assert(c.tabs[1].active && !c.tabs[0].active);
}

@("ui.dock.tabPressSlidingOffCancels")
@safe unittest
{
    enum PaneId docA = 1, docB = 2;
    DockContainer c;
    const a = c.layout.addLeaf(docA);
    const b = c.layout.addLeaf(docB);
    c.layout.root = c.layout.addTabs([a, b]);
    c.arrange(Rect(0, 0, 100, 40));

    // Press the second tab, release over the FIRST: nothing activates —
    // the defect `if (clicked && inRect)` always has.
    c.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(70, 0))));
    const r = c.handle(Event(PointerEvent(action: PointerAction.release,
        button: PointerButton.left, pos: Point(10, 0))));
    assert(r.kind == RouteKind.container);
    assert(c.paneFrames[0].pane == docA, "a slid-off press activates nothing");

    // And the pointer is free again afterwards, so the panes still work.
    const p = c.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(50, 20))));
    assert(p.kind == RouteKind.pane && p.pane == docA);
}

@("ui.dock.tabsSizeByLabelOrShareEqually")
@safe unittest
{
    // A group whose tabs are as wide as their labels, with the last one
    // flexing — the mix an application measuring its own text produces.
    enum PaneId one = 1, two = 2, three = 3;
    DockContainer c;
    const a = c.layout.addLeaf(one);
    const b = c.layout.addLeaf(two);
    const d = c.layout.addLeaf(three);
    c.layout.nodes[a].tabExtent = 12;
    c.layout.nodes[b].tabExtent = 8;
    c.layout.root = c.layout.addTabs([a, b, d]);
    c.arrange(Rect(0, 0, 60, 10));
    assert(c.tabs[0].rect.width == 12 && c.tabs[1].rect.width == 8);
    assert(c.tabs[2].rect.width == 40, "the flexing tab takes the rest");

    // A hidden pane leaves the strip entirely, and the survivors re-share.
    c.layout.setVisible(two, false);
    c.arrange(Rect(0, 0, 60, 10));
    assert(c.tabs.length == 2 && c.tabs[1].pane == three);
    assert(c.tabs[1].rect.width == 48);

    // Hiding the ACTIVE pane must not blank the group: the first visible
    // tab takes over rather than leaving an index pointing at nothing.
    c.layout.setVisible(one, false);
    c.arrange(Rect(0, 0, 60, 10));
    assert(c.paneFrames.length == 1 && c.paneFrames[0].pane == three);

    // `activate` is the programmatic route (a key binding, a set jump).
    c.layout.setVisible(one, true);
    c.layout.activate(one);
    c.arrange(Rect(0, 0, 60, 10));
    assert(c.paneFrames[0].pane == one);
}

@("ui.dock.headerIsReservedFromThePaneItBelongsTo")
@safe unittest
{
    // Both panes carry a one-row header; the sidebar is fixed, the
    // document flexes — hue's workspace with DCK10's chrome declared.
    enum PaneId side = 1, doc = 2;
    DockContainer c;
    const s = c.layout.addLeaf(side, extent: 20, minExtent: 10);
    const d = c.layout.addLeaf(doc);
    c.layout.nodes[s].headerExtent = 1;
    c.layout.nodes[s].title = "explorer";
    c.layout.nodes[d].headerExtent = 1;
    c.layout.nodes[d].title = "README.md";
    c.layout.nodes[d].headerTrailing = "2/7";
    c.layout.root = c.layout.addSplit(DockAxis.horizontal, [s, d]);
    c.focused = doc;
    c.arrange(Rect(0, 0, 100, 40));

    // The header is taken from the pane's OWN area, so the content rect
    // already excludes it: the row cannot be claimed by both.
    assert(c.headers.length == 2);
    assert(c.headers[0].rect == Rect(0, 0, 20, 1));
    assert(c.paneFrames[0].rect == Rect(0, 1, 20, 39));
    assert(c.headers[1].rect == Rect(21, 0, 79, 1));
    assert(c.paneFrames[1].rect == Rect(21, 1, 79, 39));

    // What the bar says travels with it, and so does which one reads
    // focused — the host paints, the container decides neither word nor
    // place independently of the pane.
    assert(c.headers[0].title == "explorer" && !c.headers[0].focused);
    assert(c.headers[1].title == "README.md" && c.headers[1].trailing == "2/7");
    assert(c.headers[1].focused, "the focused pane's header says so");

    // Focus moves, the chrome follows on the next arrange — no host flag.
    c.focused = side;
    c.arrange(Rect(0, 0, 100, 40));
    assert(c.headers[0].focused && !c.headers[1].focused);

    // A pane opting out costs nothing: no strip, and its content is whole.
    c.layout.nodes[d].headerExtent = 0;
    c.arrange(Rect(0, 0, 100, 40));
    assert(c.headers.length == 1);
    assert(c.paneFrames[1].rect == Rect(21, 0, 79, 40));

    // A pane too short for its header keeps its content rather than
    // rendering a bar with nothing under it.
    c.arrange(Rect(0, 0, 100, 1));
    assert(c.headers.length == 0 && c.paneFrames.length == 2);
}

@("ui.dock.contentCellExcludesTheHeaderAndTheNeighbour")
@safe unittest
{
    enum PaneId side = 1, doc = 2;
    DockContainer c;
    const s = c.layout.addLeaf(side, extent: 20);
    const d = c.layout.addLeaf(doc);
    c.layout.nodes[s].headerExtent = 1;
    c.layout.nodes[s].title = "explorer";
    c.layout.root = c.layout.addSplit(DockAxis.horizontal, [s, d]);
    c.arrange(Rect(0, 0, 100, 40));

    // Inside the sidebar's content: row 0 of the CONTENT is the row below
    // its header, not the header itself.
    Point local;
    assert(c.contentCell(Point(3, 1), side, local) && local == Point(3, 0));
    assert(c.contentCell(Point(3, 39), side, local) && local == Point(3, 38));

    // The header row is chrome: a click there is not row 0 of the content,
    // which is the confusion the hosts' own arithmetic kept producing.
    assert(!c.contentCell(Point(3, 0), side, local));

    // Neither the divider nor the other pane answers for this one.
    assert(!c.contentCell(Point(20, 5), side, local));
    assert(!c.contentCell(Point(50, 5), side, local));
    // …and the document pane, which declared no header, starts at its top.
    assert(c.contentCell(Point(50, 0), doc, local) && local == Point(29, 0));
    assert(!c.contentCell(Point(50, 0), 99, local), "an unknown pane hits nothing");
}

@("ui.dock.copyPreservesEveryField")
@safe unittest
{
    // The test that catches a copy constructor forgetting a field — which
    // it had already done for `tabStripExtent`. Set everything away from
    // its default, copy, and compare: no field list to fall out of date.
    DockLayout a;
    const l = a.addLeaf(7, extent: 5, minExtent: 2, maxExtent: 9);
    a.nodes[l].tabExtent = 11;
    a.nodes[l].headerExtent = 1;
    a.nodes[l].title = "t";
    a.nodes[l].headerCenter = "c";
    a.nodes[l].headerTrailing = "r";
    a.nodes[l].visible = false;
    const g = a.addTabs([l]);
    a.nodes[g].active = 0;
    a.root = g;
    a.dividerExtent = 3;
    a.tabStripExtent = 2;

    auto b = a;
    assert(b == a, "a copy must equal its original in every field");

    // And be independent: the arena, and each node's child list.
    b.nodes[l].title = "other";
    b.nodes[g].children[0] = 0;
    assert(a.nodes[l].title == "t");
    assert(a.nodes[g].children[0] == l);
}

@("ui.dock.reconcileDropsUnknownPanesAndCollapsesHoles")
@safe unittest
{
    // A sidebar beside a tabbed group of two documents.
    enum PaneId side = 1, docA = 2, docB = 3;
    DockLayout a;
    const s = a.addLeaf(side, extent: 20, minExtent: 10);
    const x = a.addLeaf(docA);
    const y = a.addLeaf(docB);
    const g = a.addTabs([x, y]);
    a.nodes[g].active = 1; // docB showing
    a.root = a.addSplit(DockAxis.horizontal, [s, g]);

    // Everything known: the arrangement survives, constraints included.
    const all = a.reconciled([side, docA, docB]);
    assert(all.panes() == [side, docA, docB]);
    assert(all.nodes[all.nodeOf(side)].extent == 20);
    assert(all.nodes[all.nodeOf(side)].minExtent == 10);

    // docB is gone: the group keeps one child, so it stops being a group —
    // a split of one is not a split — and `active` cannot dangle.
    const one = a.reconciled([side, docA]);
    assert(one.panes() == [side, docA]);
    foreach (ref n; one.nodes)
        assert(n.kind != DockKind.tabs, "a group of one collapsed");

    // The whole right side gone: the sidebar becomes the root, and
    // inherits the container's own extent rather than keeping a share of
    // something that no longer exists.
    const solo = a.reconciled([side]);
    assert(solo.panes() == [side]);
    assert(solo.nodes[solo.root].kind == DockKind.leaf);
    assert(solo.nodes[solo.root].pane == side);

    // The ACTIVE child dropped: the first survivor shows, rather than an
    // index pointing past the end of a shorter list.
    const noB = a.reconciled([side, docA, 99]);
    assert(noB.panes() == [side, docA]);

    // Nothing recognised: an empty layout, which is the caller's cue to
    // use its default — data, not an exception.
    const none = a.reconciled([99]);
    assert(none.nodes.length == 0);

    // Reconciling is idempotent, so a restore path can run it freely.
    assert(all.reconciled([side, docA, docB]) == all);
}

@("ui.dock.dockZoneBandsAndCorners")
@safe pure nothrow @nogc unittest
{
    const r = Rect(0, 0, 100, 40); // bands: 25 wide, 10 tall
    assert(dockZoneAt(r, Point(50, 20)) == DockZone.center);
    assert(dockZoneAt(r, Point(2, 20)) == DockZone.west);
    assert(dockZoneAt(r, Point(97, 20)) == DockZone.east);
    assert(dockZoneAt(r, Point(50, 1)) == DockZone.north);
    assert(dockZoneAt(r, Point(50, 38)) == DockZone.south);

    // A corner resolves to its NEAREST edge, not to whichever test ran
    // first — the property that keeps the hint from flickering there.
    assert(dockZoneAt(r, Point(1, 5)) == DockZone.west);
    assert(dockZoneAt(r, Point(8, 1)) == DockZone.north);

    // Outside is no zone; a rect too small for bands is all stack.
    assert(dockZoneAt(r, Point(-1, 5)) == DockZone.none);
    assert(dockZoneAt(r, Point(100, 5)) == DockZone.none);
    assert(dockZoneAt(Rect(0, 0, 2, 2), Point(1, 1)) == DockZone.center);
    assert(dockZoneAt(Rect(0, 0, 0, 0), Point(0, 0)) == DockZone.none);
}

@("ui.dock.redockSplitsStacksAndCollapsesTheOldParent")
@safe unittest
{
    enum PaneId side = 1, docA = 2, docB = 3;

    static DockLayout threePane()
    {
        DockLayout a;
        const s = a.addLeaf(side, extent: 20, minExtent: 10);
        const x = a.addLeaf(docA);
        const y = a.addLeaf(docB);
        const rightCol = a.addSplit(DockAxis.vertical, [x, y]);
        a.root = a.addSplit(DockAxis.horizontal, [s, rightCol]);
        return a;
    }

    // Drop docB east of the sidebar: it leaves the right column, which
    // collapses (a split of one is not a split), and lands beside the
    // sidebar in a horizontal split.
    auto east = threePane().redocked(docB, side, DockZone.east);
    assert(east.panes().length == 3);
    {
        DockContainer c;
        c.layout = east;
        c.arrange(Rect(0, 0, 100, 40));
        assert(c.paneFrames.length == 3);
        // A drop splits the TARGET's area, so the pair shares the
        // sidebar's 20 cells rather than taking space from docA — the
        // behaviour every dock framework has, and the reason dropping into
        // a narrow panel yields a narrow result.
        assert(c.paneFrames[0].pane == side);
        assert(c.paneFrames[1].pane == docB);
        assert(c.paneFrames[0].rect.x == 0);
        assert(c.paneFrames[0].rect.width + 1 + c.paneFrames[1].rect.width
            == 20, "the pair tiles the target's former extent");
        // docA keeps everything to the right of the original divider.
        assert(c.paneFrames[2] == PaneFrame(docA, Rect(21, 0, 79, 40)));
        // No stale group survived the move.
        foreach (ref n; east.nodes)
            if (n.kind != DockKind.leaf)
                foreach (cc; n.children)
                    assert(cc < east.nodes.length);
    }

    // Stacking onto the sidebar makes a tabbed group with the arrival
    // showing — a reader who just dropped it wants to see it.
    auto stacked = threePane().redocked(docB, side, DockZone.center);
    {
        DockContainer c;
        c.layout = stacked;
        c.arrange(Rect(0, 0, 100, 40));
        assert(c.tabs.length == 2);
        assert(c.tabs[1].pane == docB && c.tabs[1].active);
        // Only the active one has a frame, so the other cannot be hit.
        assert(c.paneFrames.length == 2);
    }

    // A second stack JOINS the group rather than nesting another one.
    auto twice = stacked.redocked(docA, side, DockZone.center);
    {
        DockContainer c;
        c.layout = twice;
        c.arrange(Rect(0, 0, 100, 40));
        assert(c.tabs.length == 3);
        size_t groups;
        foreach (ref n; twice.nodes)
            if (n.kind == DockKind.tabs)
                ++groups;
        assert(groups == 1, "joined, not nested");
    }

    // No-ops stay no-ops rather than producing a subtly different layout.
    auto base = threePane();
    assert(base.redocked(docA, docA, DockZone.east) == base);
    assert(base.redocked(docA, side, DockZone.none) == base);
    assert(base.redocked(99, side, DockZone.east) == base);
}
