/**
The tree of tabs and panes (`TSS12`, mockup E): every tab with its icon,
title, pane count and unseen mark, expandable to its panes — icon, title,
directory, a failed exit — the current tab and the focused pane marked. A
search field filters tabs and panes by title, program and directory, ranked by
`sparkles:fuzzy`; matching tabs open to show their matches.

It is the toolkit's tree component (`sparkles.ui.components.tree_view`, the
one hue's explorer and inspector use): the rows are a `TreeData` arena,
flattened through the opened set and drawn by `treeView`, with its guides,
disclosure markers and selection. A tab with one pane is one row — its title
and its directory — and a tab with several opens to them. A click selects a
row and picks it: a tab is selected, a pane focused, and a tab with panes
opens or closes; the tree stays open, so the next pick is a click away. Enter
picks the selected row and closes the tree; Left closes a tab, then climbs to
it; Right opens one. The list scrolls smoothly under the overlay scrollbar
every page uses (`SCV12`).

A surface (`surfaces.Surface`) placed as a panel — beside the rail or below the
pill (`TSS13`). The search field is at the bottom on a touch screen, within
reach of the keyboard, and at the top on the desktop.

The tree reads the workspace through a snapshot delegate and acts through a
pick delegate, so it holds no reference into the workspace's storage.
*/
module tab_tree;

import sparkles.base.text.grapheme : visibleWidth;
import sparkles.input.events : Key, KeyAction, KeyEvent, WheelEvent;
import sparkles.ui.components.dock : PaneId;
import sparkles.ui.components.tree_view : collapseOrUp, TreeViewState;
import sparkles.ui.components.tree_widget : flatten, TreeData, TreeGlyphs, treeView;
import sparkles.ui.style : FontRole, Slot, TextStyle, TypeStep;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import chrome : band, uiLabel;
import page_kit : fitCells, QueryField, ScrollBody, scrollViewport, searchRow, settleViewport;
import sparkles.ui.editor.keys : editorBinds, windowTarget;
import surfaces : Pasteable, Placement, Scrollable, Surface, SurfaceContext;

/// One pane, as the tree shows it.
struct TreePane
{
    PaneId id;
    string title;
    string icon;
    /// The directory, or how the program ended.
    string detail;
    bool focused;
    bool failed;
    bool unread;
}

/// One tab, as the tree shows it.
struct TreeTab
{
    string title;
    string icon;
    size_t unread;
    bool current;
    TreePane[] panes;
}

/// One row of the tree: a tab, or one of its panes — the `TreeData` node,
/// read by `treeView` through its capabilities.
private struct TabNode
{
    string label;
    string icon;
    string badge;
    Slot slot = Slot.textPrimary;
    Slot badgeSlot = Slot.muted;
    TextStyle textStyle;
    bool expandable;
    size_t tab;
    PaneId pane; // 0: a tab with several panes
    ulong key;   // the opened set's and the selection's identity
}

/// The hit id of arena node `i`.
private enum size_t rowHit = 0x7EE0_0000;
/// The new-tab row.
private enum size_t newTabHit = 0x7EDF_FFFF;

// A tab's key: its first pane's, in a space of its own (a pane's key is its id).
private ulong tabKey(in TreeTab tab, size_t index) @safe pure nothrow @nogc
    => (tab.panes.length ? 1UL << 32 : 2UL << 32) | (tab.panes.length ? tab.panes[0].id : index);

/// The tree of tabs and panes.
final class TabTree : Surface, Scrollable, Pasteable
{
    private TreeTab[] delegate() snapshot;
    private void delegate(size_t tab, PaneId pane) pick;
    private void delegate() newTab;
    private QueryField queryField; // the search, typed straight in (`EDU4`)
    private string query() const @safe pure nothrow @nogc => queryField.text;
    private TreeData!TabNode data;
    private TreeViewState!ulong tv;
    private ScrollBody body;
    private ulong selectedKey;  // the selection, kept across rebuilds
    private bool seeded;        // the first build opened the current tab
    private bool reveal;        // the keyboard moved: bring the selection into view
    private bool bestMatch;     // the query changed: select its first row
    private int per = 1;        // rows a row takes (a touch target is taller)

    /// `snapshot` lists the workspace now; `pick` selects a tab and, when
    /// non-zero, focuses a pane.
    this(TreeTab[] delegate() snapshot, void delegate(size_t, PaneId) pick,
        void delegate() newTab = null) @safe pure nothrow
    {
        this.snapshot = snapshot;
        this.pick = pick;
        this.newTab = newTab;
        // Selection moves the cursor through the visible rows only; the
        // viewport is the `ScrollBody`'s, so this state never scrolls.
        tv.height = int.max / 2;
    }

    WidgetTree build(in SurfaceContext ctx, int cols) @safe
    {
        rebuild(cols);
        body.touch = ctx.touch;
        body.wide = ctx.touch && ctx.wideBars;
        per = ctx.targetRows > 1 ? ctx.targetRows : 1;

        Builder b;
        uint[] lines;
        if (!ctx.touch)
        {
            // A cell above the field keeps its box off the window's edge.
            lines ~= b.add(Widget(kind: WidgetKind.column, height: SizeSpec.fixed(1)));
            lines ~= searchField(b, ctx);
        }

        const list = tv.rows.length ? rowsView(b)
            : uiLabel(b, "No tab or pane matches.", Slot.muted);
        const content = tv.rows.length ? cast(int) tv.rows.length * per : 1;

        // The rows left for the list: the panel less its top border, the
        // search field and its margin, and the New tab row. The keyboard
        // shrinks the panel; the list scrolls, the search field stays.
        const showNew = newTab !is null && !query.length;
        const areaRows = ctx.cellH > 0 && ctx.panelArea.height > 0
            ? ctx.panelArea.height / ctx.cellH : 0;
        const full = ctx.panelFull && areaRows > 0;
        const room = areaRows > 0
            ? areaRows - 1 - per - 1 - (ctx.touch ? 0 : 1) - (showNew ? per + 1 : 0) : content;
        const port = content < room ? content : room;
        // Not clipped across: a row cut at its width ends in "…" (`LAY14`).
        const v = scrollViewport(b, list, port > 1 ? port : 1, body, clipX: false);
        lines ~= v.view;
        if (showNew)
        {
            // A cell apart from the list: an action, not one more tab.
            lines ~= b.add(Widget(kind: WidgetKind.column, height: SizeSpec.fixed(1)));
            lines ~= b.add(Widget(kind: WidgetKind.row,
                children: [uiLabel(b, "+ New tab", Slot.accentPrimary)],
                width: SizeSpec.grow(), height: SizeSpec.fixed(per),
                alignY: Alignment.center, hitId: newTabHit));
        }
        // Beside the rail the tree fills its panel, the touch search at the
        // panel's bottom; below the pill it floats, as tall as its rows.
        if (full)
            lines ~= b.add(Widget(kind: WidgetKind.column, height: SizeSpec.grow()));
        if (ctx.touch)
            lines ~= searchField(b, ctx);
        const root = band(b, lines);
        if (full)
        {
            b.nodes[root].height = SizeSpec.fixed(areaRows);
            b.nodes[b.nodes[root].children[0]].height = SizeSpec.grow();
        }
        auto tree = b.finish(root);
        const sel = tv.sel * per;
        settleViewport(tree, v, content, body, reveal ? sel : -1, sel + per);
        reveal = false;
        return tree;
    }

    // The visible rows as `treeView` draws them, each `per` rows tall with
    // its text centred and the selection's band across the whole row.
    private uint rowsView(ref Builder b) @safe
    {
        TreeGlyphs glyphs;
        glyphs.leaf = "  "; // a one-pane tab's icon under a tab's
        const column = treeView(b, data, tv.rows, &isOpenNode, tv.selectedNode, glyphs,
            hitBase: cast(uint) rowHit);
        auto rows = b.nodes[column].children.dup; // `add` may move the nodes
        foreach (ref child; rows)
        {
            // The tabs are the roots: no guide joins them, only their panes.
            b.nodes[child].spans = b.nodes[child].spans[1 .. $];
            const hit = b.nodes[child].hitId;
            const selected = b.nodes[child].paintBackground;
            const states = b.nodes[child].states;
            b.nodes[child].paintBackground = false;
            b.nodes[child].width = SizeSpec.grow();
            b.nodes[child].stretch = false; // the band is the row's; its text centres in it
            child = b.add(Widget(kind: WidgetKind.panel, children: [child],
                width: SizeSpec.grow(), height: SizeSpec.fixed(per), alignY: Alignment.center,
                hitId: hit, paintBackground: selected, states: states));
        }
        b.nodes[column].children = rows;
        b.nodes[column].width = SizeSpec.grow();
        return column;
    }

    private bool isOpenNode(uint n) @safe
        => query.length > 0 || tv.open.isOpen(data.nodes[n].value.key);

    // The arena and the visible rows from the workspace now, the selection
    // kept on the same tab or pane.
    private void rebuild(int cols) @safe
    {
        data = TreeData!TabNode.init;
        foreach (ref shown; filtered())
        {
            const tab = shown.tab, ti = shown.index;
            const key = tabKey(tab, ti);
            if (!seeded && tab.current && tab.panes.length > 1)
                tv.open = tv.open.opened(key);
            const style = TextStyle(bold: tab.current, fontRole: FontRole.ui,
                typeStep: TypeStep.body);
            // A search shows the pane that matched under its tab, even the
            // only one.
            if (tab.panes.length == 1 && !query.length)
            {
                // One pane: one row, the tab's title and the pane's directory.
                const p = tab.panes[0];
                data.add(TabNode(label: tab.title, icon: tab.icon ~ " ",
                    badge: (p.unread ? "● " : "") ~ p.detail,
                    slot: p.failed ? Slot.error : tab.current ? Slot.accentPrimary : Slot.textPrimary,
                    badgeSlot: p.unread ? Slot.warn : Slot.muted, textStyle: style,
                    tab: ti, pane: p.id, key: key));
                if (!seeded && tab.current)
                    selectedKey = key;
                continue;
            }
            const parent = data.add(TabNode(label: tab.title, icon: tab.icon ~ " ",
                badge: (tab.unread ? "● " : "") ~ paneCount(tab.panes.length),
                slot: tab.current ? Slot.accentPrimary : Slot.textPrimary,
                badgeSlot: tab.unread ? Slot.warn : Slot.muted, textStyle: style,
                expandable: true, tab: ti, key: key));
            foreach (ref p; tab.panes)
            {
                data.add(TabNode(label: p.title, icon: p.icon ~ " ",
                    badge: (p.unread ? "● " : "") ~ p.detail,
                    slot: p.failed ? Slot.error : p.focused ? Slot.accentPrimary : Slot.textPrimary,
                    badgeSlot: p.unread ? Slot.warn : Slot.muted,
                    textStyle: TextStyle(bold: p.focused, fontRole: FontRole.ui,
                        typeStep: TypeStep.body),
                    tab: ti, pane: p.id, key: p.id), parent);
                if (!seeded && p.focused)
                    selectedKey = p.id;
            }
        }
        // A row too wide for the panel ends in "…" (a rich row is cut at its
        // frame bare): its name first, its detail in what is left. The room
        // is the panel less its padding, the bar, the guides and the marker.
        foreach (ref n; data.nodes)
        {
            const depth = n.parent == uint.max ? 0 : 1;
            const room = cols - 3 - 2 - 3 * depth - cast(int) visibleWidth(n.value.icon);
            n.value.label = fitCells(n.value.label, room);
            const left = room - cast(int) visibleWidth(n.value.label) - 1;
            n.value.badge = left >= 4 ? fitCells(n.value.badge, left) : "";
        }
        if (!seeded)
            reveal = true;
        seeded = true;
        tv.rows = flatten(data, &isOpenNode);
        tv.sel = 0;
        if (!bestMatch)
            foreach (i, ref r; tv.rows)
                if (data.nodes[r.node].value.key == selectedKey)
                    tv.sel = cast(long) i;
        bestMatch = false;
        tv.clamp();
        keepSelection();
    }

    // The selection's identity, from the cursor row.
    private void keepSelection() @safe pure nothrow @nogc
    {
        const n = tv.selectedNode;
        if (n != uint.max)
            selectedKey = data.nodes[n].value.key;
    }

    Placement placement() const @safe => Placement.panel;

    /// `Scrollable`: a wheel notch eases, a drag follows (`SCV12`).
    void scroll(in WheelEvent w) @system => body.scroll(w);

    /// ditto
    bool animate(float dt) @system => body.animate(dt);

    /// ditto
    ScrollBody* scrolling() @safe return => &body;

    /// A hit: the new-tab row opens one and closes the tree; a row is
    /// selected and picked — a tab with panes opens or closes too — and the
    /// tree stays.
    bool activate(size_t id) @system
    {
        if (id == newTabHit && newTab !is null)
        {
            newTab();
            return true;
        }
        if (id < rowHit || id - rowHit >= data.nodes.length)
            return false;
        const node = cast(uint)(id - rowHit);
        foreach (i, ref r; tv.rows)
            if (r.node == node)
                tv.sel = cast(long) i;
        keepSelection();
        const v = data.nodes[node].value;
        if (v.expandable)
            tv.open = tv.open.toggled(v.key);
        pick(v.tab, v.pane);
        return false;
    }

    /// Enter: picks the selected row and closes the tree.
    bool confirm() @system
    {
        const n = tv.selectedNode;
        if (n == uint.max)
            return false;
        const v = data.nodes[n].value;
        pick(v.tab, v.pane);
        return true;
    }

    void cancel() @system {}

    bool key(in KeyEvent k) @system
    {
        // A desktop key arrives twice, pressed and released; the release
        // is the press's, and moving on it too stepped two rows a press.
        if (k.action == KeyAction.release)
            return true;
        switch (k.key)
        {
            case Key.up, Key.down, Key.pageUp, Key.pageDown:
                const page = body.viewport / per > 1 ? body.viewport / per : 1;
                tv.moveSel(k.key == Key.up ? -1 : k.key == Key.down ? 1
                    : k.key == Key.pageUp ? -page : page);
                break;
            case Key.home:
                tv.selHome();
                break;
            case Key.end:
                tv.selEnd();
                break;
            case Key.left:
                if (!query.length)
                {
                    collapseOrUp(tv, data, (uint n) => data.nodes[n].value.key);
                    break;
                }
                goto default; // with a query, the arrows move its caret
            case Key.right:
                const n = tv.selectedNode;
                if (!query.length)
                {
                    if (n != uint.max && data.nodes[n].value.expandable)
                    {
                        if (!tv.open.isOpen(data.nodes[n].value.key))
                            tv.open = tv.open.opened(data.nodes[n].value.key);
                        else if (tv.sel + 1 < cast(long) tv.rows.length)
                            tv.moveSel(1); // already open: into its first pane
                    }
                    break;
                }
                goto default;
            default:
                // The query's editor; Enter and Escape are the overlay's.
                if (k.key == Key.enter || k.key == Key.escape)
                    return false;
                if ((k.mods.ctrl || k.mods.alt || k.mods.super_)
                    && !editorBinds(k, windowTarget))
                    return false;
                const r = queryField.key(k);
                if (!r.handled)
                    return false;
                // The rows still hold the old results: the next rebuild
                // selects the new best match.
                if (r.changed)
                    bestMatch = true;
                break;
        }
        keepSelection();
        reveal = true;
        return true;
    }

    /// A paste into the search (`EDI4`).
    bool paste(scope const(char)[] text) @system
    {
        if (queryField.paste(text).changed)
        {
            bestMatch = true;
            keepSelection();
            reveal = true;
        }
        return true;
    }

    /// The query typed so far.
    const(char)[] search() const @safe pure nothrow @nogc => query;

    /// The tabs to show: all of them, or — with a query — the tabs whose
    /// title matches, with every pane, and the tabs with matching panes,
    /// with those only, best first.
    private Shown[] filtered() @trusted
    {
        auto tabs = snapshot();
        Shown[] result;
        if (!query.length)
        {
            foreach (i, tab; tabs)
                result ~= Shown(tab, i);
            return result;
        }

        import std.algorithm.sorting : sort;

        static struct Ranked
        {
            Shown shown;
            long score;
        }

        Ranked[] kept;
        foreach (index, tab; tabs)
        {
            const own = score(tab.title);
            TreePane[] panes;
            long best = own;
            foreach (p; tab.panes)
            {
                const s = score(p.title ~ " " ~ p.detail);
                if (s > 0 || own > 0)
                    panes ~= p;
                if (s > best)
                    best = s;
            }
            if (best > 0)
                kept ~= Ranked(Shown(TreeTab(tab.title, tab.icon, tab.unread, tab.current,
                    own > 0 ? tab.panes : panes), index), best);
        }
        kept.sort!((a, b) => a.score > b.score);
        foreach (k; kept)
            result ~= k.shown;
        return result;
    }

    // A tab as shown, with its index in the workspace: a pick names that, not
    // its place in a filtered list.
    private static struct Shown
    {
        TreeTab tab;
        size_t index;
    }

    /// `sparkles:fuzzy`'s score for `text` against the query; 0 when not
    /// admitted.
    private long score(const(char)[] text) @safe => fuzzyScore(query, text);

    // The logs' search row (`TPG8`): typing goes straight to the query, so
    // the caret shows once there is one.
    private uint searchField(ref Builder b, in SurfaceContext ctx) @safe
        => searchRow(b, query.idup, query.length > 0, "Search tabs, panes, programs, dirs",
            ctx.targetRows, inBand: true);

    private static string paneCount(size_t n) @safe
    {
        import std.conv : text;

        return text(n, " panes");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.ui.glyphs : ActionIcon, iconText;

    private TreeTab[] sample() @safe
    {
        return [
            TreeTab("~/sparkles", "❯", 0, true, [
                TreePane(1, "zsh", "❯", "~/sparkles", focused: true),
                TreePane(2, "htop", "▤", "pid 8812"),
                TreePane(3, "nix build", "✗", "exited 1", failed: true),
            ]),
            TreeTab("nvim spec.md", "≡", 0, false, [TreePane(4, "nvim viewer.md", "≡", "~/docs")]),
            TreeTab("build", "▶", 1, false, [
                TreePane(5, "nix build .#hue-apk", "✓", "done", unread: true),
                TreePane(6, "zsh", "❯", "~/build"),
            ]),
        ];
    }

    private size_t[] picked;

    private TabTree tree() @safe
    {
        picked = null;
        return new TabTree(() => sample(), (size_t t, PaneId p) { picked = [t, p]; });
    }

    private const(char)[][] texts(in WidgetTree t) @safe
    {
        const(char)[][] r;
        foreach (ref n; t.nodes)
        {
            if (n.text.length)
                r ~= n.text;
            foreach (ref s; n.spans)
                if (s.text.length)
                    r ~= s.text;
        }
        return r;
    }

    // The hit id of the row labelled `label` in `t`.
    private size_t hitOf(in WidgetTree t, string label) @safe
    {
        foreach (ref n; t.nodes)
            foreach (ref s; n.spans)
                if (s.text == label)
                    return n.hitId;
        assert(false, label);
    }
}

@("tab_tree.build.currentTabOpenOthersClosed")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto t = tree();
    const shown = texts(t.build(SurfaceContext.init, 40));
    assert(shown.canFind("~/sparkles") && shown.canFind("build"));
    assert(shown.canFind("zsh") && !shown.canFind("nix build .#hue-apk"),
        "only the current tab is open");
    assert(shown.canFind("● 2 panes"), "the unseen mark on its tab");
    assert(shown[0] == iconText(ActionIcon.search), "the search field on top on the desktop");

    SurfaceContext touch = {touch: true};
    const last = texts(t.build(touch, 40));
    assert(last[$ - 2] == iconText(ActionIcon.search), "at the bottom on touch");
}

@("tab_tree.build.aOnePaneTabIsOneRow")
@system unittest
{
    import std.algorithm.searching : canFind, count;

    // The tab is its pane: its title once, the pane's directory beside it,
    // no "1 pane" and no pane row repeating the title.
    auto t = tree();
    const shown = texts(t.build(SurfaceContext.init, 40));
    assert(shown.count("nvim spec.md") == 1 && shown.canFind("~/docs"));
    assert(!shown.canFind("nvim viewer.md") && !shown.canFind("1 pane"));

    // A click picks its pane.
    t.activate(hitOf(t.build(SurfaceContext.init, 40), "nvim spec.md"));
    assert(picked == [1, 4]);
}

@("tab_tree.activate.aClickKeepsTheTreeOpen")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto t = tree();
    auto built = t.build(SurfaceContext.init, 40);

    // A pane: focused, and the tree stays.
    assert(!t.activate(hitOf(built, "htop")), "a pick does not close the tree");
    assert(picked == [0, 2]);

    // A closed tab with panes: selected, and opened.
    assert(!t.activate(hitOf(built, "build")));
    assert(picked == [2, 0]);
    built = t.build(SurfaceContext.init, 40);
    assert(texts(built).canFind("nix build .#hue-apk"), "the click opened it");

    // Again: closed.
    t.activate(hitOf(built, "build"));
    assert(!texts(t.build(SurfaceContext.init, 40)).canFind("nix build .#hue-apk"));
}

@("tab_tree.key.leftClosesRightOpens")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto t = tree();
    t.build(SurfaceContext.init, 40); // the focused pane selected
    assert(t.key(KeyEvent(Key.left)), "Left climbs to the tab");
    assert(t.key(KeyEvent(Key.left)), "then closes it");
    assert(!texts(t.build(SurfaceContext.init, 40)).canFind("htop"));
    assert(t.key(KeyEvent(Key.right)));
    assert(texts(t.build(SurfaceContext.init, 40)).canFind("htop"), "Right opens it");
}

@("tab_tree.key.searchOpensMatchingTabs")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto t = tree();
    foreach (dchar c; "hue-apk")
        assert(t.key(KeyEvent(Key.char_, c)));
    const shown = texts(t.build(SurfaceContext.init, 40));
    assert(shown.canFind("nix build .#hue-apk"), "the match opens its tab");
    assert(!shown.canFind("htop"), "a tab without a match is gone");

    // Enter picks the first row, that tab, and closes the tree.
    assert(t.confirm());
    assert(picked == [2, 0], "the workspace's index, not the filtered list's");

    // Down to the pane, then Enter: it is focused.
    assert(t.key(KeyEvent(Key.down)));
    t.build(SurfaceContext.init, 40);
    assert(t.confirm() && picked[1] == 5);

    // Backspace widens again.
    foreach (_; 0 .. 7)
        assert(t.key(KeyEvent(Key.backspace)));
    assert(t.search == "");
}

@("tab_tree.key.anEditedQuerySelectsTheBestMatch")
@system unittest
{
    auto t = tree();
    t.build(SurfaceContext.init, 40);
    // "~/sparkles" is the first row and still matches (its "nix build"
    // pane), but the tab named "build" ranks first.
    foreach (dchar c; "build")
        assert(t.key(KeyEvent(Key.char_, c)));
    t.build(SurfaceContext.init, 40);
    assert(t.confirm());
    assert(picked[0] == 2, "the best match, not the row selected before the search");
}

@("tab_tree.key.anEditedQuerySelectsTheBestMatch")
@system unittest
{
    // The first tab still matches "vim" by its title, but "vim" ranks first.
    static TreeTab[] two() @safe => [
        TreeTab("old vim notes", "≡", 0, true, [TreePane(1, "zsh", "❯", "~/notes")]),
        TreeTab("vim", "≡", 0, false, [TreePane(2, "vim", "≡", "~/src")]),
    ];
    size_t[] chosen;
    auto t = new TabTree(() => two(), (size_t tab, PaneId p) { chosen = [tab, p]; });
    t.build(SurfaceContext.init, 40);
    foreach (dchar c; "vim")
        assert(t.key(KeyEvent(Key.char_, c)));
    t.build(SurfaceContext.init, 40);
    assert(t.confirm());
    assert(chosen[0] == 1, "the best match, not the row selected before the search");
}

@("tab_tree.key.clusterBackspaceAndInvalidScalar")
@system unittest
{
    auto t = tree();
    assert(t.key(KeyEvent(Key.char_, 'a')));
    assert(t.key(KeyEvent(Key.char_, '\u0301')));
    assert(!t.key(KeyEvent(Key.char_, cast(dchar) 0xD800)));
    assert(t.search == "a\u0301");
    assert(t.key(KeyEvent(Key.backspace)));
    assert(t.search == "");
}

/**
`sparkles:fuzzy`'s score for `text` against `query`, plus one; 0 when the
query does not admit it (or does not parse). Shared by the searches that rank
a short list: the tab tree, the key guide.
*/
long fuzzyScore(scope const(char)[] query, scope const(char)[] text) @trusted
{
    import sparkles.fuzzy.common : CandidateView;
    import sparkles.fuzzy.match : match, MatcherWorkspace;
    import sparkles.fuzzy.query : parseQuery;

    // Heap, once: the workspace is far larger than a test worker's stack.
    static MatcherWorkspace!()* workspace;
    if (workspace is null)
        workspace = new MatcherWorkspace!();
    auto q = parseQuery(query, workspace.textWorkspace);
    if (!q.hasValue)
        return 0;
    CandidateView c;
    c.id.low = 1;
    c.path = text;
    auto r = match(q.value, c, *workspace);
    return r.hasValue && r.value.admitted ? 1 + r.value.score : 0;
}

@("tab_tree.build.besideTheRailItFillsThePanel")
@system unittest
{
    import sparkles.ui.geometry : Rect;

    import chrome : place, Place;

    // Mockup E: beside the rail the tree slides out at the panel's full
    // height, its touch search at the bottom; below the pill it floats.
    auto t = tree();
    SurfaceContext rail = {touch: true, cellW: 1, cellH: 1, panelArea: Rect(0, 0, 40, 30),
        panelFull: true};
    const full = place(t.build(rail, 40), 40, 30, 0, 0, 1, 1, Place.top);
    assert(full.bounds.height == 30);
    foreach (i, ref n; full.tree.nodes)
        if (n.text == iconText(ActionIcon.search))
            assert(full.frames[i].rect.y == 28, "the search field above a cell of margin");

    SurfaceContext pill = rail;
    pill.panelFull = false;
    assert(place(t.build(pill, 40), 40, 30, 0, 0, 1, 1, Place.top).bounds.height < 30);
}

@("tab_tree.build.aShortPanelScrollsTheList")
@system unittest
{
    import sparkles.ui.geometry : Rect;

    import chrome : place, Place;

    // The keyboard up: a panel of 12 rows for 5 rows of tabs and panes, a
    // new-tab row and the search field, each 2 rows tall. The list scrolls
    // under the overlay bar; the search field stays on the panel.
    auto t = new TabTree(() => sample(), (size_t, PaneId) {}, () {});
    SurfaceContext kb = {touch: true, cellW: 1, cellH: 1, targetRows: 2,
        panelArea: Rect(0, 0, 40, 12)};
    const l = place(t.build(kb, 40), 40, 12, 0, 0, 1, 1, Place.top);
    assert(l.bounds.height <= 12, "the panel's height, not the list's");
    bool search;
    foreach (i, ref n; l.tree.nodes)
        if (n.text == iconText(ActionIcon.search))
            search = l.frames[i].rect.y + l.frames[i].rect.height <= 12;
    assert(search, "the search field shows");
    assert(t.scrolling.content == 12 && t.scrolling.viewport == 5, "the list overflows its port");

    // Moving the selection down scrolls the list to it.
    foreach (_; 0 .. 4)
        t.key(KeyEvent(Key.down));
    t.build(kb, 40);
    assert(t.scrolling.motion.target > 0, "the view follows the selection");
}

@("tab_tree.key.aReleaseDoesNotMoveAgain")
@system unittest
{
    auto t = tree();
    t.build(SurfaceContext.init, 40);
    const from = t.tv.sel;
    KeyEvent up = KeyEvent(Key.down);
    up.action = KeyAction.release;
    assert(t.key(KeyEvent(Key.down)) && t.key(up), "both are the tree's");
    assert(t.tv.sel == from + 1, "one press, one row");
}

@("tab_tree.build.aLongTitleEndsInAnEllipsis")
@system unittest
{
    import std.algorithm.searching : any, endsWith, startsWith;

    auto t = new TabTree(() => [TreeTab("a-very-long-window-title-that-will-not-fit", "❯", 0, true,
        [TreePane(1, "zsh", "❯", "/home/someone/a/very/deep/directory")])], (size_t, PaneId) {});
    const shown = texts(t.build(SurfaceContext.init, 24));
    assert(shown.any!(s => s.endsWith("…") && s.length > 3), "the title is cut with an ellipsis");
    foreach (s; shown)
        if (!s.startsWith("Search")) // the placeholder is cut where it is painted
            assert(visibleWidth(s) <= 24 - 3, s);
}
