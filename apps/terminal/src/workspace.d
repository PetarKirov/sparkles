/**
The terminal's tabs and splits as a value (`TSS6`, `TSS8`, `TSS14`, `TSS15`):
an ordered list of tabs, each a `DockLayout` of panes, with the focus, the
zoom and what each pane runs. No `TerminalView` lives here — panes are ids,
the instances are the embedder's `TerminalPool` — so every operation is pure,
testable without a pty, and the whole workspace serializes for restore.

Operations refuse rather than overflow: 32 tabs, 16 panes in a tab
($(LREF maxTabs), $(LREF maxPanesPerTab)); a refusal is a value the caller
turns into a toast.
*/
module workspace;

import std.path : dirName;

import sparkles.ui.components.dock : DividerFrame, DockAxis, DockFrames, dockFrames,
    DockLayout, DockZone, PaneId;
import sparkles.ui.geometry : Rect;

/// The workspace's limits (`TSS6`).
enum size_t maxTabs = 32;
/// ditto
enum size_t maxPanesPerTab = 16;

/// Why an operation did nothing.
enum Refusal : ubyte
{
    none,         /// it happened
    tooManyTabs,  /// a 33rd tab
    tooManyPanes, /// a 17th pane in a tab
    nothing,      /// nothing to act on (no such pane, a single tab to cycle)
}

/// What a pane runs, and what restore re-creates (`TSS14`).
struct PaneSpec
{
    PaneId id;
    /// A user rename: wins over the program's title (`TPR1`).
    string titlePin;
    /// The working directory, as OSC 7 last reported it (`TPR4`).
    string cwd;
    /// An explicit command (`terminal -- cmd`, a "run command" pane); empty
    /// for the user's shell.
    string command;
    /// A viewer pane's file (`TDV5`): set, the pane shows this document in
    /// the embedded viewer instead of running a program, and restore re-opens
    /// it.
    string document;

    /// Whether this is a viewer pane.
    bool isDocument() const @safe pure nothrow @nogc => document.length != 0;
}

/// Where an opened file goes (`TDV2`), the workspace's half of `open.target`.
enum Placement : ubyte
{
    tab,        /// a new tab after the current one
    splitRight, /// a split to the right of the requesting pane
    splitDown,  /// a split below it
}

/// One tab: a layout of panes, the focused one and the zoomed one (0: none).
struct Tab
{
    string titlePin;
    DockLayout layout;
    PaneId focused;
    PaneId zoomed;

    /// ditto
    this(string titlePin, DockLayout layout, PaneId focused, PaneId zoomed) @safe
    {
        this.titlePin = titlePin;
        this.layout = DockLayout(layout);
        this.focused = focused;
        this.zoomed = zoomed;
    }

    /// A deep copy: the layout's arena is copied with it (`DCK1`).
    this(ref return scope const Tab other) @safe
    {
        titlePin = other.titlePin;
        layout = DockLayout(other.layout);
        focused = other.focused;
        zoomed = other.zoomed;
    }
}

/// Directions for focus movement.
enum Direction : ubyte
{
    left,
    right,
    up,
    down,
}

/// Where divider `d` sits along its axis, in cells.
int dividerAt(in DividerFrame d) @safe pure nothrow @nogc
    => d.axis == DockAxis.horizontal ? d.rect.x : d.rect.y;

/**
`pos` clamped to where divider `d` may go: the dock's bounds, narrowed so
neither neighbour gets under four cells where there is room for that.
*/
int dividerClamp(in DividerFrame d, int pos) @safe pure nothrow @nogc
{
    // The dock's bounds already leave each neighbour one cell; three more.
    enum keep = 3;
    const roomy = d.lo + keep <= d.hi - keep;
    const lo = roomy ? d.lo + keep : d.lo, hi = roomy ? d.hi - keep : d.hi;
    return pos < lo ? lo : pos > hi ? hi : pos;
}

/// The tabs and splits.
struct Workspace
{
    Tab[] tabs;
    size_t current;
    PaneSpec[] panes;
    /// The last id minted; ids are never reused within a run.
    PaneId lastId;

    // ── reading ─────────────────────────────────────────────────────────

    /// Whether there is nothing left (the last pane closed: quit, `TSS5`).
    bool empty() const @safe pure nothrow @nogc => tabs.length == 0;

    /// The focused pane of the current tab, 0 when empty.
    PaneId focused() const @safe pure nothrow @nogc
        => tabs.length ? tabs[current].focused : 0;

    /// The spec of `id`, or null.
    inout(PaneSpec)* spec(PaneId id) inout @safe pure nothrow @nogc return
    {
        foreach (ref p; panes)
            if (p.id == id)
                return &p;
        return null;
    }

    /// The tab holding `id`, or `size_t.max`.
    size_t tabOf(PaneId id) const @safe pure nothrow @nogc
    {
        foreach (i, ref t; tabs)
            if (t.layout.nodeOf(id) != uint.max)
                return i;
        return size_t.max;
    }

    /// The panes of tab `t`, in layout order.
    PaneId[] panesOf(size_t t) const @safe
        => t < tabs.length ? tabs[t].layout.panes() : null;

    /**
    The current tab's geometry within `area` (cells): every pane's rect and
    the dividers, or — while a pane is zoomed — that pane alone filling the
    area (`TSS8`).
    */
    void frames(in Rect area, ref DockFrames f) const @safe
    {
        if (!tabs.length)
        {
            dockFrames(DockLayout.init, area, f);
            return;
        }
        const t = &tabs[current];
        if (t.zoomed)
        {
            DockLayout solo;
            solo.root = solo.addLeaf(t.zoomed);
            dockFrames(solo, area, f, t.focused);
            return;
        }
        dockFrames(t.layout, area, f, t.focused);
    }

    // ── tabs ────────────────────────────────────────────────────────────

    /**
    Opens a tab with one pane running `command` (empty: the shell) in `cwd`,
    after the current tab, and selects it. Returns the new pane, or 0 with
    `why` set.
    */
    PaneId newTab(string cwd, string command, out Refusal why) @safe
    {
        if (tabs.length >= maxTabs)
        {
            why = Refusal.tooManyTabs;
            return 0;
        }
        const id = mint(cwd, command);
        Tab t;
        t.layout.root = t.layout.addLeaf(id);
        t.focused = id;
        const at = tabs.length ? current + 1 : 0;
        tabs = tabs[0 .. at] ~ t ~ tabs[at .. $];
        current = at;
        return id;
    }

    /// Selects tab `i` (0-based); false when there is no such tab.
    bool selectTab(size_t i) @safe pure nothrow @nogc
    {
        if (i >= tabs.length)
            return false;
        current = i;
        return true;
    }

    /// The next or previous tab, wrapping; false with a single tab.
    bool cycleTab(int step) @safe pure nothrow @nogc
    {
        if (tabs.length < 2)
            return false;
        const n = cast(long) tabs.length;
        current = cast(size_t)(((cast(long) current + step) % n + n) % n);
        return true;
    }

    /// Pins (or, empty, clears) the current tab's title.
    void renameTab(string title) @safe pure nothrow @nogc
    {
        if (tabs.length)
            tabs[current].titlePin = title;
    }

    // ── panes ───────────────────────────────────────────────────────────

    /**
    Splits the focused pane: `DockAxis.horizontal` puts the new pane to its
    right, `vertical` below it. The new pane runs the shell in the focused
    pane's directory (`TSS8`) and takes the focus; a zoom ends.
    */
    PaneId split(DockAxis axis, out Refusal why) @safe
        => splitWith(axis, null, why);

    /**
    Opens `path` in a viewer pane (`TDV2`, `TDV5`): a new tab, or a split
    beside `from` — the pane whose program asked — which is focused first.
    A `from` that is gone opens a tab. The new pane takes the focus; it
    starts in the file's directory, so a split or tab made from it does too.
    */
    PaneId openDocument(string path, Placement where, PaneId from, out Refusal why) @safe
    {
        if (where == Placement.tab || tabOf(from) == size_t.max)
        {
            const id = newTab(path.dirName, null, why);
            if (id)
                spec(id).document = path;
            return id;
        }
        cast(void) focusPane(from);
        return splitWith(where == Placement.splitRight ? DockAxis.horizontal
            : DockAxis.vertical, path, why);
    }

    private PaneId splitWith(DockAxis axis, string document, out Refusal why) @safe
    {
        if (!tabs.length)
        {
            why = Refusal.nothing;
            return 0;
        }
        auto t = &tabs[current];
        if (t.layout.panes().length >= maxPanesPerTab)
        {
            why = Refusal.tooManyPanes;
            return 0;
        }
        const from = spec(t.focused);
        const id = mint(document.length ? document.dirName
            : from !is null ? from.cwd : null, null);
        spec(id).document = document;

        // A leaf for the new pane beside the root, then moved next to the
        // focused one: `redocked` owns the split's construction rules.
        DockLayout wrapped = DockLayout(t.layout);
        const leaf = wrapped.addLeaf(id);
        wrapped.root = wrapped.addSplit(DockAxis.horizontal, [wrapped.root, leaf]);
        t.layout = wrapped.redocked(id, t.focused,
            axis == DockAxis.horizontal ? DockZone.east : DockZone.south);
        t.focused = id;
        t.zoomed = 0;
        return id;
    }

    /**
    Closes pane `id` wherever it is. Its tab closes with its last pane; the
    focus moves to what the layout shows in its place. Returns false when
    there was no such pane.
    */
    bool close(PaneId id) @safe
    {
        const ti = tabOf(id);
        if (ti == size_t.max)
            return false;
        foreach (i, ref p; panes)
            if (p.id == id)
            {
                panes = panes[0 .. i] ~ panes[i + 1 .. $];
                break;
            }
        auto t = &tabs[ti];
        PaneId[] keep;
        foreach (p; t.layout.panes())
            if (p != id)
                keep ~= p;
        if (!keep.length)
        {
            tabs = tabs[0 .. ti] ~ tabs[ti + 1 .. $];
            if (current >= tabs.length && current > 0)
                current = tabs.length - 1;
            else if (ti < current)
                current--;
            return true;
        }
        t.layout = t.layout.reconciled(keep);
        if (t.zoomed == id)
            t.zoomed = 0;
        if (t.focused == id)
            t.focused = t.layout.firstPane(t.layout.root);
        return true;
    }

    /**
    Focuses `id` from outside (`TSS15`, a notification, the log): selects its
    tab, ends a zoom on another pane, focuses it. False for an unknown pane.
    */
    bool focusPane(PaneId id) @safe pure nothrow @nogc
    {
        const ti = tabOf(id);
        if (ti == size_t.max)
            return false;
        current = ti;
        auto t = &tabs[ti];
        if (t.zoomed && t.zoomed != id)
            t.zoomed = 0;
        t.focused = id;
        t.layout.activate(id);
        return true;
    }

    /**
    Moves the focus to the nearest pane in `d` within the current tab laid out
    in `area`: one whose rect lies beyond the focused one's edge and overlaps
    it across, the closest first. False when there is none (or a zoom).
    */
    bool focusToward(Direction d, in Rect area) @safe
    {
        if (!tabs.length || tabs[current].zoomed)
            return false;
        DockFrames f;
        frames(area, f);
        Rect from;
        bool have;
        foreach (ref p; f.panes)
            if (p.pane == focused)
            {
                from = p.rect;
                have = true;
            }
        if (!have)
            return false;

        PaneId best;
        long bestGap = long.max;
        foreach (ref p; f.panes)
        {
            if (p.pane == focused)
                continue;
            const r = p.rect;
            long gap;
            bool across;
            final switch (d)
            {
                case Direction.left:
                    gap = from.x - (r.x + r.width);
                    across = r.y < from.y + from.height && from.y < r.y + r.height;
                    break;
                case Direction.right:
                    gap = r.x - (from.x + from.width);
                    across = r.y < from.y + from.height && from.y < r.y + r.height;
                    break;
                case Direction.up:
                    gap = from.y - (r.y + r.height);
                    across = r.x < from.x + from.width && from.x < r.x + r.width;
                    break;
                case Direction.down:
                    gap = r.y - (from.y + from.height);
                    across = r.x < from.x + from.width && from.x < r.x + r.width;
                    break;
            }
            if (across && gap >= 0 && gap < bestGap)
            {
                bestGap = gap;
                best = p.pane;
            }
        }
        if (!best)
            return false;
        tabs[current].focused = best;
        return true;
    }

    /// Toggles the focused pane filling its tab (`TSS8`).
    void toggleZoom() @safe pure nothrow @nogc
    {
        if (!tabs.length)
            return;
        auto t = &tabs[current];
        t.zoomed = t.zoomed ? 0 : t.focused;
    }

    /**
    Resizes a split of the current tab (`TSS10`): the child before the divider
    takes `extent` cells along the split's axis and the one after it flexes.
    */
    void resizeSplit(uint beforeNode, uint afterNode, int extent) @safe pure nothrow @nogc
    {
        if (!tabs.length || extent < 1)
            return;
        auto nodes = tabs[current].layout.nodes;
        if (beforeNode >= nodes.length || afterNode >= nodes.length)
            return;
        nodes[beforeNode].extent = extent;
        nodes[afterNode].extent = 0;
    }

    /**
    Moves divider `d` (one of `frames`'s) to `pos` along its axis, clamped by
    `dividerClamp`; false when it stays where it is (`TSS10`).
    */
    bool moveDivider(in DividerFrame d, int pos) @safe pure nothrow @nogc
    {
        pos = dividerClamp(d, pos);
        if (pos == dividerAt(d))
            return false;
        resizeSplit(d.beforeNode, d.afterNode, pos - d.start);
        return true;
    }

    /**
    Moves the focused pane's border toward `d` by `step` cells (`TSS8`): the
    divider on that side when there is one, which grows the pane, else the one
    on the opposite side, which shrinks it — as tmux's `resize-pane` does.
    False when no divider borders the pane along that axis, or it is pinned.
    */
    bool resizeToward(Direction d, in Rect area, int step = 2) @safe
    {
        if (!tabs.length || tabs[current].zoomed)
            return false;
        DockFrames f;
        frames(area, f);
        Rect p;
        bool have;
        foreach (ref pf; f.panes)
            if (pf.pane == focused)
            {
                p = pf.rect;
                have = true;
            }
        if (!have)
            return false;

        const across = d == Direction.left || d == Direction.right;
        const axis = across ? DockAxis.horizontal : DockAxis.vertical;
        const forward = d == Direction.right || d == Direction.down;
        // Whether `v` borders the pane on its far (`after`) or near side.
        bool borders(in DividerFrame v, bool after)
        {
            const r = v.rect;
            if (across)
                return (after ? r.x == p.x + p.width : r.x + r.width == p.x)
                    && r.y <= p.y && p.y + p.height <= r.y + r.height;
            return (after ? r.y == p.y + p.height : r.y + r.height == p.y)
                && r.x <= p.x && p.x + p.width <= r.x + r.width;
        }
        foreach (side; [forward, !forward])
            foreach (ref v; f.dividers)
                if (v.axis == axis && borders(v, side))
                    return moveDivider(v, dividerAt(v) + (forward ? step : -step));
        return false;
    }

    /// Records a pane's working directory (OSC 7, `TPR4`).
    void setCwd(PaneId id, string cwd) @safe pure nothrow @nogc
    {
        if (auto p = spec(id))
            p.cwd = cwd;
    }

    private PaneId mint(string cwd, string command) @safe pure nothrow
    {
        const id = ++lastId;
        panes ~= PaneSpec(id: id, cwd: cwd, command: command);
        return id;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Restore (`TSS14`).
// ─────────────────────────────────────────────────────────────────────────────

/// The workspace as saved: what restore needs and nothing else.
struct SavedWorkspace
{
    /// Bumped when the shape changes incompatibly; an unknown one is discarded.
    int format = 1;
    Tab[] tabs;
    size_t current;
    PaneSpec[] panes;
}

/// The saved form of `w`.
SavedWorkspace saved(in Workspace w) @safe
{
    SavedWorkspace s;
    foreach (ref t; w.tabs)
        s.tabs ~= Tab(t.titlePin, DockLayout(t.layout), t.focused, t.zoomed);
    s.current = w.current;
    s.panes = w.panes.dup;
    return s;
}

/**
The workspace a saved one describes, made consistent: a tab whose layout
names a pane with no spec loses it (and is dropped when that leaves it
empty), the focus and zoom are re-pointed when they name a lost pane, the
current tab is clamped, and new ids continue after the largest kept one.
Empty when nothing usable survived — the caller starts fresh.
*/
Workspace restored(SavedWorkspace s) @safe
{
    Workspace w;
    if (s.format != SavedWorkspace.init.format)
        return w;
    PaneId[] known;
    foreach (ref p; s.panes)
        known ~= p.id;
    foreach (ref t; s.tabs)
    {
        auto layout = t.layout.reconciled(known);
        if (!layout.nodes.length)
            continue;
        const ids = layout.panes();
        bool has(PaneId id)
        {
            foreach (x; ids)
                if (x == id)
                    return true;
            return false;
        }

        Tab k = Tab(t.titlePin, layout, t.focused, t.zoomed);
        if (!has(k.focused))
            k.focused = layout.firstPane(layout.root);
        if (k.zoomed && !has(k.zoomed))
            k.zoomed = 0;
        w.tabs ~= k;
        foreach (id; ids)
            foreach (ref p; s.panes)
                if (p.id == id)
                {
                    w.panes ~= p;
                    if (id > w.lastId)
                        w.lastId = id;
                }
    }
    w.current = s.current < w.tabs.length ? s.current : (w.tabs.length ? w.tabs.length - 1 : 0);
    return w;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private Workspace oneTab(out PaneId first) @safe
    {
        Workspace w;
        Refusal why;
        first = w.newTab("/home", null, why);
        assert(first && why == Refusal.none);
        return w;
    }

    private enum Rect screen = Rect(0, 0, 80, 24);
}

@("workspace.splitFocusAndClose")
@safe unittest
{
    PaneId a;
    auto w = oneTab(a);
    Refusal why;
    const b = w.split(DockAxis.horizontal, why);
    assert(b && w.focused == b, "a split takes the focus");
    assert(w.spec(b).cwd == "/home", "in the focused pane's directory (TSS8)");
    const c = w.split(DockAxis.vertical, why);
    assert(w.panesOf(0).length == 3);

    // a | b over c: the geometry says b is right of a, c below b.
    DockFrames f;
    w.frames(screen, f);
    Rect ra, rb, rc;
    foreach (ref p; f.panes)
        (p.pane == a ? ra : p.pane == b ? rb : rc) = p.rect;
    assert(rb.x > ra.x && rc.y > rb.y && rc.x == rb.x);

    assert(w.focusToward(Direction.up, screen) && w.focused == b);
    assert(w.focusToward(Direction.left, screen) && w.focused == a);
    assert(!w.focusToward(Direction.left, screen), "nothing further left");
    assert(w.focusToward(Direction.right, screen));

    // Closing the focused pane hands the focus on; the last pane takes the
    // tab and then the workspace with it.
    assert(w.close(w.focused));
    assert(w.panesOf(0).length == 2 && w.focused != 0);
    assert(w.close(b) || w.close(c));
    foreach (id; w.panesOf(0).dup)
        assert(w.close(id));
    assert(w.empty, "the last pane quits (TSS5)");
}

@("workspace.tabsCycleAndLimits")
@safe unittest
{
    PaneId a;
    auto w = oneTab(a);
    Refusal why;
    assert(!w.cycleTab(1), "one tab does not cycle");
    const b = w.newTab("/tmp", "htop", why);
    assert(w.current == 1 && w.spec(b).command == "htop");
    assert(w.cycleTab(1) && w.current == 0);
    assert(w.cycleTab(-1) && w.current == 1);

    while (w.tabs.length < maxTabs)
        cast(void) w.newTab(null, null, why);
    assert(w.newTab(null, null, why) == 0 && why == Refusal.tooManyTabs);

    PaneId first;
    auto x = oneTab(first);
    while (x.panesOf(0).length < maxPanesPerTab)
        cast(void) x.split(DockAxis.horizontal, why);
    assert(x.split(DockAxis.vertical, why) == 0 && why == Refusal.tooManyPanes);
}

@("workspace.zoomAndFocusFromOutside")
@safe unittest
{
    PaneId a;
    auto w = oneTab(a);
    Refusal why;
    const b = w.split(DockAxis.horizontal, why);
    w.toggleZoom();
    DockFrames f;
    w.frames(screen, f);
    assert(f.panes.length == 1 && f.panes[0].pane == b && f.panes[0].rect == screen);

    const c = w.newTab(null, null, why);
    assert(w.current == 1 && w.focused == c);

    // A notification names `a`: its tab is selected, b's zoom ends (TSS15).
    assert(w.focusPane(a));
    assert(w.current == 0 && w.focused == a && w.tabs[0].zoomed == 0);
    assert(!w.focusPane(999));
}

@("workspace.savedRoundTripsAndDegrades")
@system unittest
{
    import sparkles.wired.json : fromJSON, toJSON;

    PaneId a;
    auto w = oneTab(a);
    Refusal why;
    const b = w.split(DockAxis.vertical, why);
    w.setCwd(b, "/srv");
    w.renameTab("work");
    cast(void) w.newTab("/tmp", "make test", why);

    auto text = toJSON(saved(w));
    assert(!text.hasError, text.error.toString);
    auto back = fromJSON!SavedWorkspace(text.value[]);
    assert(!back.hasError, back.error.toString);
    auto r = restored(back.value);
    assert(r.tabs.length == 2 && r.current == 1);
    assert(r.tabs[0].titlePin == "work" && r.panesOf(0).length == 2);
    assert(r.spec(b).cwd == "/srv");
    assert(r.lastId == w.lastId, "new ids continue after the kept ones");

    // A pane whose spec is gone drops out; an unknown format is discarded.
    auto s = saved(w);
    s.panes = s.panes[1 .. $];
    auto partial = restored(s);
    assert(partial.panesOf(0).length == 1 && partial.focused != 0);
    s.format = 99;
    assert(restored(s).empty);
}

@("workspace.resizeSplit.movesTheDivider")
@safe unittest
{
    PaneId a;
    auto w = oneTab(a);
    Refusal why;
    cast(void) w.split(DockAxis.horizontal, why);
    DockFrames f;
    w.frames(screen, f);
    assert(f.dividers.length == 1);
    const d = f.dividers[0];
    w.resizeSplit(d.beforeNode, d.afterNode, 20);
    w.frames(screen, f);
    assert(f.panes[0].rect.width == 20 || f.panes[1].rect.width == 20, "the left pane is 20 wide");
}

@("workspace.openDocument.tabOrSplitBesideTheRequester")
@system unittest
{
    import sparkles.wired.json : fromJSON, toJSON;

    PaneId a;
    auto w = oneTab(a);
    Refusal why;
    const b = w.split(DockAxis.horizontal, why);

    // A split opens beside the pane that asked, not the focused one, and
    // takes the focus (`TDV2`).
    const v = w.openDocument("/srv/notes/README.md", Placement.splitDown, a, why);
    assert(v && w.focused == v && w.spec(v).isDocument);
    assert(w.spec(v).cwd == "/srv/notes", "a viewer starts in its file's directory");
    DockFrames f;
    w.frames(screen, f);
    Rect ra, rv;
    foreach (ref p; f.panes)
        if (p.pane == a)
            ra = p.rect;
        else if (p.pane == v)
            rv = p.rect;
    assert(rv.y > ra.y && rv.x == ra.x, "below the requester");
    assert(!w.spec(b).isDocument);

    // A tab; and a requester that is gone opens a tab too.
    const t = w.openDocument("/tmp/x.csv", Placement.tab, a, why);
    assert(w.current == 1 && w.focused == t && w.panesOf(1).length == 1);
    const g = w.openDocument("/tmp/y.png", Placement.splitRight, 999, why);
    assert(w.tabs.length == 3 && w.focused == g);

    // Restore re-opens the path (`TDV5`).
    auto text = toJSON(saved(w));
    assert(!text.hasError);
    auto back = fromJSON!SavedWorkspace(text.value[]);
    assert(!back.hasError, back.error.toString);
    assert(restored(back.value).spec(v).document == "/srv/notes/README.md");
}

@("workspace.resizeToward.growsTowardElseShrinks")
@safe unittest
{
    PaneId a;
    auto w = oneTab(a);
    Refusal why;
    const b = w.split(DockAxis.horizontal, why);
    assert(w.focused == b);

    int widthOf(PaneId id)
    {
        DockFrames f;
        w.frames(screen, f);
        foreach (ref p; f.panes)
            if (p.pane == id)
                return p.rect.width;
        return 0;
    }

    // The right pane has a divider on its left only: Left grows it, Right
    // moves that same divider back — the pane shrinks.
    const before = widthOf(b);
    assert(w.resizeToward(Direction.left, screen));
    assert(widthOf(b) == before + 2);
    assert(w.resizeToward(Direction.right, screen));
    assert(widthOf(b) == before);
    assert(!w.resizeToward(Direction.up, screen), "no divider along that axis");

    // Never past four cells of the other pane.
    foreach (_; 0 .. 100)
        cast(void) w.resizeToward(Direction.left, screen);
    assert(widthOf(a) == 4);
}
