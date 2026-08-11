/**
The interactive tree view (`TRV1`–`TRV7`) — the interaction half of the tree
component, completing the three-layer split whose data and view halves live in
$(MREF sparkles,ui,components,tree_widget):

$(LIST
    * $(B data) — $(REF TreeData, sparkles,ui,components,tree_widget), the flat
        arena. Owned by the adapter, rebuilt at will.
    * $(B interaction) ($(LREF TreeViewState)) — the opened set, the cursor,
        the viewport and both scrollbars, and the live filter's editor: every
        piece of state a tree pane keeps between frames, as $(B one value).
    * $(B view) — $(REF treeView, sparkles,ui,components,tree_widget) over the
        $(LREF viewSlice) window this state selects.
)

Before this module the interaction layer existed three times — hue's explorer
pane, hue's GUI re-implementation of the same pane, and the gallery's tree
page each carried their own copy of "move through the $(I visible) rows",
"left closes, then climbs", and the scrollbar-grab-owns-the-pointer pointer
arms. The behaviors here are those, stated once:

$(LIST
    * The cursor moves by visible row, never by arena index — pressing down
        inside a closed folder cannot land on a node nobody can see.
    * $(LREF TreeViewState.clamp) couples the cursor and the viewport: the
        cursor stays in view, and the view never shows dead space below the
        last row.
    * $(LREF collapseOrUp) is the universal two-step Left: close an open
        node, else climb to its parent's row.
    * A press on a scrollbar is a grab, never a row click, and the grab owns
        the pointer until release wherever the drag strays (STM9's inverse
        mapping, same as the viewer's).
    * The live filter is the one line-edit machine (STM13); every edit asks
        the adapter to rebuild, because in broot's tree-as-search-result mode
        the tree $(I is) a function of the query.
)

What is deliberately $(B not) here: the node model and its rebuild policy
(lazy children, filtering predicates, git decoration — the adapter's), and
painting (a host slices with $(LREF viewSlice) and paints through its own
canvas). Mutations that invalidate the visible rows return
$(LREF TreeStep)`.rebuild` rather than calling anything: the adapter owns
rebuilding, the state only reports that it is needed.
*/
module sparkles.ui.components.tree_view;

import sparkles.base.term_color : RgbColor;
import sparkles.input : InputKey = Key, KeyEvent, PointerAction,
    PointerButton, PointerEvent;
import sparkles.ui.components.scroll_view : ScrollView;
import sparkles.ui.components.tree_widget : FlatTreeRow, TreeData, TreeGlyphs,
    treeView;
import sparkles.ui.state : DisclosureState, LineEditState, ScrollbarState;
import sparkles.ui.widget : Builder;

@safe:

/// What an interaction did, and what the caller owes it.
enum TreeStep : ubyte
{
    none,      /// not this component's — the caller may use the input itself
    handled,   /// consumed; the rows are still valid
    rebuild,   /// consumed; the opened set or filter changed — rebuild rows
    activated, /// a selected row was activated — the adapter decides what that means
}

/**
The tree pane's interaction state (`VMD2` + the viewport): one value a host
embeds, keyed by the adapter's node identity `Key` (a path for a filesystem
tree, a node index for an in-memory one) so the opened set survives rebuilds.

`sel`/`top` index the $(B visible rows), not the arena. `rows` is the cached
result of the adapter's last flatten — derived data stored here so every
motion and clamp can see how many rows exist without a callback.
*/
struct TreeViewState(Key)
{
    /// User intent (`VMD5`): which nodes should be open, keyed by identity.
    DisclosureState!Key open;
    /// The visible rows, as the adapter last rebuilt them.
    FlatTreeRow[] rows;
    /// Cursor row and first visible row (indices into `rows`).
    long sel;
    /// ditto
    long top;
    /// Both scrollbars' machines + easings as one value (SCV1).
    ScrollView scroll;
    /// Widest visible row in cells — the horizontal bar's content extent.
    int contentCols;
    /// The live filter's editor (STM13); `filter.active` IS filter mode.
    LineEditState filter;
    /// Pane geometry: outer size, and rows of pane chrome above/below the
    /// tree (header + status bars; a chromeless pane sets 0).
    int width, height;
    /// ditto
    int chromeRows = 2;

    /// The vertical/horizontal scrollbar machines, by their customary names.
    ref inout(ScrollbarState) sb() inout return pure nothrow @nogc
        => scroll.v;
    /// ditto
    ref inout(ScrollbarState) hsb() inout return pure nothrow @nogc
        => scroll.h;

    /// Rows available to the tree body once the chrome has its share.
    int bodyRows() const pure nothrow @nogc
        => height > chromeRows ? height - chromeRows : 1;

    /// The selected row's node, or `uint.max` when there is none.
    uint selectedNode() const pure nothrow @nogc
        => sel >= 0 && sel < cast(long) rows.length
            ? rows[cast(size_t) sel].node : uint.max;

    /// Whether the horizontal bar is live (content wider than the pane).
    bool hOverflows() const pure nothrow @nogc
        => contentCols > width - 1 && width > 2;

    /// Whether pane-local `(x, y)` sits on the live vertical bar's column —
    /// the host's pointer-shape hover check.
    bool overScrollbar(int x, int y) const pure nothrow @nogc
        => cast(long) rows.length > bodyRows && x == width - 1
            && y >= 1 && y <= bodyRows;

    /// ditto for the horizontal bar's row (above the status bar, when live).
    bool overHScrollbar(int x, int y) const pure nothrow @nogc
        => hOverflows() && y == height - 2 && x >= 0 && x < width - 1;

    /// The pane is consuming typed text (a host must not steal keys).
    bool searching() const pure nothrow @nogc => filter.active;

    /// The live-filter query (for a host that paints its own input line).
    const(char)[] filterQuery() const return pure nothrow @nogc
        => filter.text;

    /// Moves the cursor by `dy` visible rows (`±1` step, `±bodyRows` page),
    /// keeping it in view.
    void moveSel(long dy) pure nothrow @nogc
    {
        sel += dy;
        clamp();
    }

    /// Home / End, through the same clamp.
    void selHome() pure nothrow @nogc
    {
        sel = 0;
        clamp();
    }

    /// ditto
    void selEnd() pure nothrow @nogc
    {
        sel = cast(long) rows.length - 1;
        clamp();
    }

    /// Scrolls the viewport by `dy` rows (the wheel), leaving the cursor
    /// where it is; the next cursor move re-snaps the view to it.
    void scrollBy(long dy) pure nothrow @nogc
    {
        top += dy;
        const maxTop = cast(long) rows.length - bodyRows;
        if (top > maxTop)
            top = maxTop;
        if (top < 0)
            top = 0;
    }

    /// Couples cursor and viewport: the cursor stays valid and in view, and
    /// the view never leaves dead space below the last row (a reveal before
    /// the pane had its real height can overshoot; the next sized clamp
    /// pulls back).
    void clamp() pure nothrow @nogc
    {
        const n = cast(long) rows.length;
        if (sel >= n) sel = n ? n - 1 : 0;
        if (sel < 0) sel = 0;
        if (sel < top) top = sel;
        if (sel >= top + bodyRows) top = sel - bodyRows + 1;
        const maxTop = n - bodyRows;
        if (top > maxTop) top = maxTop;
        if (top < 0) top = 0;
    }

    /// `/`: enter filter mode. Every filter mutation reports `rebuild` —
    /// the tree is a function of the query.
    TreeStep filterStart() pure nothrow
    {
        filter = filter.started();
        return TreeStep.rebuild;
    }

    /// One key while the filter owns the keyboard: characters narrow, Enter
    /// keeps the filtered tree, Esc clears it. `none` for keys that are not
    /// the editor's (a host may route them elsewhere or drop them).
    TreeStep filterKey(in KeyEvent e) pure nothrow
    {
        switch (e.key)
        {
            case InputKey.char_:
                const next = filter.typed(e.ch);
                if (next == filter)
                    return TreeStep.handled;
                filter = next;
                return TreeStep.rebuild;
            case InputKey.backspace:
                filter = filter.erased();
                return TreeStep.rebuild;
            case InputKey.enter:
                filter = filter.accepted();
                return TreeStep.handled;
            case InputKey.escape:
                filter = filter.cancelled();
                return TreeStep.rebuild;
            default:
                return TreeStep.none;
        }
    }

    /**
    One pointer event, in pane-local cells. The precedence is load-bearing
    and shared by every consumer:

    $(OL
        $(LI a release lets go of both bars' grabs;)
        $(LI the horizontal bar's row, then the vertical bar's column — a
            press there is a grab, never a row click, and an existing grab
            owns the pointer wherever the drag strays;)
        $(LI a press on a body row selects it; a press on the $(I already)
            selected row activates it (the caller runs its meaning).)
    )
    */
    TreeStep pointer(in PointerEvent p) pure nothrow @nogc
    {
        if (p.button != PointerButton.left)
            return TreeStep.handled;
        if (p.action == PointerAction.release)
        {
            sb = sb.released();
            hsb = hsb.released();
            return TreeStep.handled;
        }
        if ((p.action == PointerAction.press && hOverflows()
                && p.pos.y == height - 2 && p.pos.x >= 0
                && p.pos.x < width - 1)
            || (p.action == PointerAction.drag && hsb.dragging))
        {
            hsb = p.action == PointerAction.press && !hsb.dragging
                ? hsb.pressed(p.pos.x, contentCols, width - 1, width - 1)
                : hsb.dragged(p.pos.x, contentCols, width - 1, width - 1);
            return TreeStep.handled;
        }
        const overflows = cast(long) rows.length > bodyRows;
        if ((p.action == PointerAction.press && overflows
                && p.pos.x == width - 1 && p.pos.y >= 1
                && p.pos.y <= bodyRows)
            || (p.action == PointerAction.drag && sb.dragging))
        {
            sb = p.action == PointerAction.press && !sb.dragging
                ? sb.scrolledTo(top).pressed(p.pos.y - 1,
                    rows.length, bodyRows, bodyRows)
                : sb.scrolledTo(top).dragged(p.pos.y - 1,
                    rows.length, bodyRows, bodyRows);
            top = sb.offset;
            scrollBy(0); // clamp top without moving the selection
            return TreeStep.handled;
        }
        if (p.action == PointerAction.press && p.pos.y >= 1
            && p.pos.y <= bodyRows)
        {
            const i = top + (p.pos.y - 1);
            if (i >= 0 && i < cast(long) rows.length)
            {
                const already = i == sel;
                sel = i;
                if (already)
                    return TreeStep.activated;
            }
        }
        return TreeStep.handled;
    }
}

/**
The universal two-step Left (`TRV3`): close the selected node when it is open,
else move the cursor to its parent's row. `keyOf` maps a node index to the
adapter's disclosure key.

Returns `rebuild` when the opened set changed (the adapter re-flattens),
`handled` otherwise.
*/
TreeStep collapseOrUp(Key, T, KeyOf)(ref TreeViewState!Key s,
    in TreeData!T data, scope KeyOf keyOf)
{
    if (s.sel >= cast(long) s.rows.length)
        return TreeStep.handled;
    const node = s.rows[cast(size_t) s.sel].node;
    if (data.hasChildren(node) && s.open.isOpen(keyOf(node)))
    {
        s.open = s.open.closed(keyOf(node));
        return TreeStep.rebuild;
    }
    const p = data.nodes[node].parent;
    if (p == uint.max)
        return TreeStep.handled;
    foreach (i, ref const r; s.rows)
        if (r.node == p)
        {
            s.sel = cast(long) i;
            break;
        }
    s.clamp();
    return TreeStep.handled;
}

/**
Enter / a second click (`TRV7`): a node with children toggles its disclosure
(`rebuild`); a leaf reports `activated` — its meaning (open the file, pick
the CST node) is the adapter's. An adapter whose expandability is not
"has children" (an empty directory still toggles) supplies `expandable`.
*/
TreeStep activate(Key, T, KeyOf)(ref TreeViewState!Key s,
    in TreeData!T data, scope KeyOf keyOf)
{
    const node = s.selectedNode;
    if (node == uint.max)
        return TreeStep.handled;
    bool toggles = data.hasChildren(node);
    static if (__traits(compiles,
        { bool e = data.nodes[node].value.expandable; }))
        toggles = data.nodes[node].value.expandable;
    if (toggles)
    {
        s.open = s.open.toggled(keyOf(node));
        return TreeStep.rebuild;
    }
    return TreeStep.activated;
}

/// The next/prev row (cyclic, in tree order) whose node satisfies `pred` —
/// hue's `]g`/`[g` change navigation, generalized. No-op when none matches.
void jumpMatching(Key, Pred)(ref TreeViewState!Key s, int dir, scope Pred pred)
{
    const n = cast(long) s.rows.length;
    if (n == 0)
        return;
    foreach (step; 1 .. n + 1)
    {
        const i = ((s.sel + dir * step) % n + n) % n;
        if (pred(s.rows[cast(size_t) i].node))
        {
            s.sel = i;
            s.clamp();
            return;
        }
    }
}

/**
Recomputes the widest visible row in cells (`contentCols`) from the same
node capabilities the renderer reads: per-depth guide cells (3), the marker
column (3), the label, and a badge's two cells when one is present.
*/
void measureContent(Key, T)(ref TreeViewState!Key s, in TreeData!T data)
{
    import sparkles.ui.geometry : cellsOf;

    s.contentCols = 0;
    foreach (ref const r; s.rows)
    {
        ref const v = data.nodes[r.node].value;
        static if (__traits(compiles, { const(char)[] l = v.label; }))
            const(char)[] label = v.label;
        else
            const(char)[] label = v;
        int w = r.depth * 3 + 3 + cast(int) cellsOf(label);
        static if (__traits(compiles, { const(char)[] bt = v.badge; }))
            w += v.badge.length ? 2 : 0;
        if (w > s.contentCols)
            s.contentCols = w;
    }
    s.hsb = s.hsb.scrolledTo(s.hsb.offset); // clamp happens at paint/drag
}

/**
The viewport slice both backends were computing by hand: the `[top ..
top + bodyRows)` window of the visible rows, rendered through
$(REF treeView, sparkles,ui,components,tree_widget) with the selection
carried across (guides are per-row, so slicing is safe).
*/
uint viewSlice(Key, T)(ref Builder b, in TreeData!T data,
    in TreeViewState!Key s, scope bool delegate(uint) @safe isOpen,
    TreeGlyphs glyphs = TreeGlyphs.init,
    RgbColor selectionBg = RgbColor.init, bool hasSelectionBg = false,
    uint hitBase = 1)
{
    const first = cast(size_t)(s.top < 0 ? 0 : s.top);
    const last = first + s.bodyRows > s.rows.length ? s.rows.length
        : first + s.bodyRows;
    return treeView(b, data, s.rows[first < last ? first : last .. last],
        isOpen, s.selectedNode, glyphs, selectionBg, hasSelectionBg, hitBase);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input : Point;
    import sparkles.ui.components.tree_widget : flatten;

    // src/{app.d, ui/{widget.d, layout.d}}, docs — keyed by node index.
    private TreeData!string sample() pure nothrow
    {
        TreeData!string t;
        const src = t.add("src");
        t.add("app.d", src);
        const ui = t.add("ui", src);
        t.add("widget.d", ui);
        t.add("layout.d", ui);
        t.add("docs");
        return t;
    }

    private void rebuild(ref TreeViewState!uint s, in TreeData!string data)
    {
        // The adapter in miniature: rows are a function of (data, open).
        auto open = s.open;
        s.rows = flatten(data, (uint n) => open.isOpen(n));
        s.measureContent(data);
        s.clamp();
    }
}

@("ui.tree_view.cursorMovesThroughVisibleRowsAndClamps")
@safe unittest
{
    auto data = sample();
    TreeViewState!uint s;
    s.width = 30;
    s.height = 6; // bodyRows = 4 < 6 rows
    s.open = DisclosureState!uint.allOpen;
    rebuild(s, data);
    assert(s.rows.length == 6);

    // Step, page, home/end — all clamped to the visible rows.
    s.moveSel(1);
    assert(s.sel == 1 && s.top == 0);
    s.selEnd();
    assert(s.sel == 5, "End lands on the last row");
    assert(s.top == 2, "…and the viewport follows the cursor");
    s.moveSel(100);
    assert(s.sel == 5, "over-stepping clamps");
    s.selHome();
    assert(s.sel == 0 && s.top == 0);

    // Closing a subtree: the hidden rows are unreachable by construction.
    s.open = s.open.closed(2); // ui/
    rebuild(s, data);
    assert(s.rows.length == 4);
    s.sel = 2; // ui/ row
    s.moveSel(1);
    assert(s.rows[cast(size_t) s.sel].node == 5,
        "down from a closed node lands on the next VISIBLE row");
}

@("ui.tree_view.clampNeverLeavesDeadSpaceBelow")
@safe unittest
{
    auto data = sample();
    TreeViewState!uint s;
    s.width = 30;
    s.height = 12; // bodyRows = 10 > 6 rows: everything fits
    s.open = DisclosureState!uint.allOpen;
    rebuild(s, data);

    s.top = 4; // an overshoot (e.g. a reveal before the pane was sized)
    s.clamp();
    assert(s.top == 0, "a viewport taller than the content shows it all");

    s.height = 5; // bodyRows = 3
    s.scrollBy(100);
    assert(s.top == 3, "scroll clamps to the last full viewport");
}

@("ui.tree_view.collapseOrUpClosesThenClimbs")
@safe unittest
{
    auto data = sample();
    TreeViewState!uint s;
    s.width = 30;
    s.height = 10;
    s.open = DisclosureState!uint.allOpen;
    rebuild(s, data);

    // On an open dir: closes (and asks for a rebuild).
    s.sel = 2; // ui/
    assert(collapseOrUp(s, data, (uint n) => n) == TreeStep.rebuild);
    assert(!s.open.isOpen(2));
    rebuild(s, data);

    // On the now-closed dir: climbs to the parent's row.
    assert(s.rows[cast(size_t) s.sel].node == 2);
    assert(collapseOrUp(s, data, (uint n) => n) == TreeStep.handled);
    assert(s.rows[cast(size_t) s.sel].node == 0, "climbed to src");

    // src is itself still open, so Left closes it too…
    assert(collapseOrUp(s, data, (uint n) => n) == TreeStep.rebuild);
    rebuild(s, data);

    // …and on a CLOSED root with no parent, Left is a no-op.
    assert(s.rows[cast(size_t) s.sel].node == 0);
    assert(collapseOrUp(s, data, (uint n) => n) == TreeStep.handled);
    assert(s.rows[cast(size_t) s.sel].node == 0);
}

@("ui.tree_view.activateTogglesParentsAndReportsLeaves")
@safe unittest
{
    auto data = sample();
    TreeViewState!uint s;
    s.width = 30;
    s.height = 10;
    rebuild(s, data); // everything closed: two roots visible

    s.sel = 0; // src (has children)
    assert(activate(s, data, (uint n) => n) == TreeStep.rebuild);
    assert(s.open.isOpen(0));
    rebuild(s, data);

    s.sel = 1; // app.d — a leaf
    assert(activate(s, data, (uint n) => n) == TreeStep.activated);
}

@("ui.tree_view.filterMachineReportsRebuilds")
@safe unittest
{
    TreeViewState!uint s;
    assert(s.filterStart() == TreeStep.rebuild);
    assert(s.searching);
    assert(s.filterKey(KeyEvent(InputKey.char_, 'a')) == TreeStep.rebuild);
    assert(s.filterQuery == "a");
    assert(s.filterKey(KeyEvent(InputKey.backspace)) == TreeStep.rebuild);
    assert(s.filterKey(KeyEvent(InputKey.enter)) == TreeStep.handled);
    assert(!s.searching, "Enter keeps the tree and leaves input mode");
    assert(s.filterStart() == TreeStep.rebuild);
    assert(s.filterKey(KeyEvent(InputKey.escape)) == TreeStep.rebuild);
    assert(!s.searching && s.filterQuery.length == 0, "Esc clears");
    assert(s.filterKey(KeyEvent(InputKey.f5)) == TreeStep.none,
        "keys that are not the editor's are declined, not eaten");
}

@("ui.tree_view.scrollbarGrabIsNotARowClick")
@safe unittest
{
    auto data = sample();
    TreeViewState!uint s;
    s.width = 30;
    s.height = 5; // bodyRows = 3 < 6 rows: the bar is live
    s.open = DisclosureState!uint.allOpen;
    rebuild(s, data);

    // A press on the track jumps the view; the selection stays put.
    assert(s.pointer(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(29, 3))) == TreeStep.handled);
    assert(s.sb.dragging);
    assert(s.sel == 0, "a scrollbar press never selects a row");
    assert(s.top > 0, "a track press jumped to the pointer");

    // The grab owns the pointer off the column; release ends it.
    const grabbed = s.top;
    assert(s.pointer(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(10, 1))) == TreeStep.handled);
    assert(s.top < grabbed && s.sel == 0);
    s.pointer(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(10, 1)));
    assert(!s.sb.dragging);

    // Off the bars, a press selects; a second press on the same row activates.
    const want = s.top + 1;
    assert(s.pointer(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(5, 2))) == TreeStep.handled);
    assert(s.sel == want);
    assert(s.pointer(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(5, 2))) == TreeStep.activated);
}

@("ui.tree_view.jumpMatchingIsCyclicAndClamped")
@safe unittest
{
    auto data = sample();
    TreeViewState!uint s;
    s.width = 30;
    s.height = 10;
    s.open = DisclosureState!uint.allOpen;
    rebuild(s, data);

    // Nodes 1 and 4 "match"; the scan cycles and skips everything else.
    bool hit(uint n) @safe => n == 1 || n == 4;
    s.jumpMatching(1, &hit);
    assert(s.rows[cast(size_t) s.sel].node == 1);
    s.jumpMatching(1, &hit);
    assert(s.rows[cast(size_t) s.sel].node == 4);
    s.jumpMatching(1, &hit);
    assert(s.rows[cast(size_t) s.sel].node == 1, "wraps around");
    s.jumpMatching(-1, &hit);
    assert(s.rows[cast(size_t) s.sel].node == 4, "…both ways");

    // With no match the cursor does not move.
    s.sel = 0;
    s.jumpMatching(1, (uint) @safe => false);
    assert(s.sel == 0);
}

@("ui.tree_view.viewSliceWindowsTheRows")
@safe unittest
{
    import sparkles.ui.widget : WidgetKind;

    auto data = sample();
    TreeViewState!uint s;
    s.width = 30;
    s.height = 5; // bodyRows = 3
    s.open = DisclosureState!uint.allOpen;
    rebuild(s, data);
    s.sel = 4;
    s.clamp(); // top = 2

    auto b = Builder();
    const col = viewSlice(b, data, s, (uint) @safe => true);
    auto wt = b.finish(col);
    assert(wt.nodes[col].children.length == 3, "exactly the viewport's rows");

    // The selected row is inside the slice and carries the selection slot.
    import sparkles.ui.style : Slot;

    bool sawSelection;
    foreach (c; wt.nodes[col].children)
        sawSelection |= wt.nodes[c].slot == Slot.selection;
    assert(sawSelection);
}
