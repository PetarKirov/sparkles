/**
The tree of tabs and panes (`TSS12`, mockup E): every tab with its icon,
title, pane count and unseen mark, expandable to its panes — icon, title,
directory, a failed exit — the current tab and the focused pane marked. A
search field filters tabs and panes by title, program and directory, ranked by
`sparkles:fuzzy`; matching tabs open to show their matches. Choosing an entry
selects its tab and focuses its pane, and closes the tree.

A surface (`surfaces.Surface`) placed as a panel — beside the rail or below the
pill (`TSS13`). The search field is at the bottom on a touch screen, within
reach of the keyboard, and at the top on the desktop.

The tree reads the workspace through a snapshot delegate and acts through a
pick delegate, so it holds no reference into the workspace's storage.
*/
module tab_tree;

import sparkles.input.events : Key, KeyEvent;
import sparkles.ui.components.dock : PaneId;
import sparkles.ui.style : Slot;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;

import chrome : band, label, row;
import surfaces : Placement, Surface, SurfaceContext;

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

/// A row of the tree as built: which tab and pane it stands for.
private struct Row
{
    size_t tab;
    PaneId pane; // 0: the tab row
}

/// The hit id of row `i`.
private enum size_t rowHit = 0x7EE0_0000;
/// The new-tab row.
private enum size_t newTabHit = 0x7EDF_FFFF;

/// The tree of tabs and panes.
final class TabTree : Surface
{
    private TreeTab[] delegate() snapshot;
    private void delegate(size_t tab, PaneId pane) pick;
    private void delegate() newTab;
    private char[] query;
    private size_t selected;
    private Row[] rows;

    /// `snapshot` lists the workspace now; `pick` selects a tab and, when
    /// non-zero, focuses a pane.
    this(TreeTab[] delegate() snapshot, void delegate(size_t, PaneId) pick,
        void delegate() newTab = null) @safe pure nothrow
    {
        this.snapshot = snapshot;
        this.pick = pick;
        this.newTab = newTab;
    }

    WidgetTree build(in SurfaceContext ctx, int cols) @safe
    {
        Builder b;
        uint[] lines;
        if (!ctx.touch)
            lines ~= searchField(b, ctx);

        rows.length = 0;
        foreach (ti, tab; filtered())
        {
            const open = tab.current || query.length;
            const hit = rowHit + rows.length;
            rows ~= Row(ti, 0);
            lines ~= entry(b, ctx, (open ? "▾ " : "▸ ") ~ tab.icon ~ " " ~ tab.title,
                tab.panes.length == 1 ? "1 pane" : paneCount(tab.panes.length),
                tab.unread ? "●" : "", tab.current, false, hit);
            if (open)
                foreach (ref p; tab.panes)
                {
                    const h = rowHit + rows.length;
                    rows ~= Row(ti, p.id);
                    lines ~= entry(b, ctx, "    " ~ p.icon ~ " " ~ p.title, "      " ~ p.detail,
                        p.unread ? "●" : "", p.focused, p.failed, h);
                }
        }
        if (!rows.length)
            lines ~= label(b, "No tab or pane matches.", Slot.muted);
        if (newTab !is null && !query.length)
        {
            lines ~= b.add(Widget(kind: WidgetKind.row,
                children: [label(b, "+ New tab", Slot.accentPrimary)],
                width: SizeSpec.grow(),
                height: ctx.targetRows > 1 ? SizeSpec.fixed(ctx.targetRows) : SizeSpec.fit_,
                hitId: newTabHit));
        }
        // Beside the rail the tree fills its panel, the touch search at the
        // panel's bottom; below the pill it floats, as tall as its rows.
        const full = ctx.panelFull && ctx.cellH > 0 && ctx.panelArea.height > 0;
        if (full)
            lines ~= b.add(Widget(kind: WidgetKind.column, height: SizeSpec.grow()));
        if (ctx.touch)
            lines ~= searchField(b, ctx);
        const root = band(b, lines);
        if (full)
        {
            b.nodes[root].height = SizeSpec.fixed(ctx.panelArea.height / ctx.cellH);
            b.nodes[b.nodes[root].children[0]].height = SizeSpec.grow();
        }
        return b.finish(root);
    }

    Placement placement() const @safe => Placement.panel;

    bool activate(size_t id) @system
    {
        if (id == newTabHit && newTab !is null)
        {
            newTab();
            return true;
        }
        if (id < rowHit || id - rowHit >= rows.length)
            return false;
        const r = rows[id - rowHit];
        pick(r.tab, r.pane);
        return true;
    }

    bool confirm() @system
    {
        if (!rows.length)
            return false;
        return activate(rowHit + (selected < rows.length ? selected : 0));
    }

    void cancel() @system {}

    bool key(in KeyEvent k) @system
    {
        import std.utf : encode;

        switch (k.key)
        {
            case Key.up:
                if (selected > 0)
                    selected--;
                return true;
            case Key.down:
                if (selected + 1 < rows.length)
                    selected++;
                return true;
            case Key.backspace:
                if (query.length)
                {
                    import std.utf : strideBack;

                    query.length -= strideBack(query, query.length);
                    selected = 0;
                }
                return true;
            case Key.char_:
                if (k.ch < 0x20 || k.mods.ctrl || k.mods.alt)
                    return false;
                char[4] buf;
                query ~= buf[0 .. encode(buf, k.ch)];
                selected = 0;
                return true;
            default:
                return false;
        }
    }

    /// The query typed so far.
    const(char)[] search() const @safe pure nothrow @nogc => query;

    /// The tabs to show: all of them, or — with a query — the tabs whose
    /// title matches, with every pane, and the tabs with matching panes,
    /// with those only, best first.
    private TreeTab[] filtered() @trusted
    {
        auto tabs = snapshot();
        if (!query.length)
            return tabs;

        import std.algorithm.sorting : sort;

        static struct Ranked
        {
            TreeTab tab;
            long score;
        }

        Ranked[] kept;
        foreach (tab; tabs)
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
                kept ~= Ranked(TreeTab(tab.title, tab.icon, tab.unread, tab.current,
                    own > 0 ? tab.panes : panes), best);
        }
        kept.sort!((a, b) => a.score > b.score);
        TreeTab[] result;
        foreach (k; kept)
            result ~= k.tab;
        return result;
    }

    /// `sparkles:fuzzy`'s score for `text` against the query; 0 when not
    /// admitted.
    private long score(const(char)[] text) @safe => fuzzyScore(query, text);

    private uint searchField(ref Builder b, in SurfaceContext ctx) @safe
    {
        const text = query.length ? "⌕ " ~ query.idup : "⌕ Search tabs, panes, programs, dirs";
        return b.add(Widget(kind: WidgetKind.panel,
            children: [label(b, text, query.length ? Slot.textPrimary : Slot.muted)],
            slot: Slot.surfaceSunken, paintBackground: true));
    }

    private uint entry(ref Builder b, in SurfaceContext ctx, string title, string detail,
        string badge, bool marked, bool failed, size_t hit) @safe
    {
        const line = row(b, [label(b, title, failed ? Slot.error
            : marked ? Slot.accentPrimary : Slot.textPrimary, bold: marked),
            label(b, badge, Slot.warn)]);
        uint[] kids = [line];
        if (detail.length)
            kids ~= label(b, detail, Slot.muted);
        const selectedNow = rows.length && hit - rowHit == selected;
        return b.add(Widget(kind: WidgetKind.column, children: kids,
            height: ctx.targetRows > 1 ? SizeSpec.fixed(ctx.targetRows) : SizeSpec.fit_,
            width: SizeSpec.grow(), hitId: hit,
            slot: selectedNow ? Slot.chromeFocused : Slot.inherit,
            paintBackground: selectedNow));
    }

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
    private TreeTab[] sample() @safe
    {
        return [
            TreeTab("~/sparkles", "❯", 0, true, [
                TreePane(1, "zsh", "❯", "~/sparkles", focused: true),
                TreePane(2, "htop", "▤", "pid 8812"),
                TreePane(3, "nix build", "✗", "exited 1", failed: true),
            ]),
            TreeTab("nvim spec.md", "≡", 0, false, [TreePane(4, "nvim viewer.md", "≡", "~/docs")]),
            TreeTab("build", "▶", 1, false, [TreePane(5, "nix build .#hue-apk", "✓", "done", unread: true)]),
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
            if (n.text.length)
                r ~= n.text;
        return r;
    }
}

@("tab_tree.build.currentTabOpenOthersClosed")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto t = tree();
    const shown = texts(t.build(SurfaceContext.init, 40));
    assert(shown.canFind("▾ ❯ ~/sparkles") && shown.canFind("▸ ≡ nvim spec.md"));
    assert(shown.canFind("    ❯ zsh") && !shown.canFind("    ≡ nvim viewer.md"),
        "only the current tab is open");
    assert(shown.canFind("●"), "the unseen mark");
    assert(shown[0].canFind("⌕"), "the search field on top on the desktop");

    SurfaceContext touch = {touch: true};
    assert(texts(t.build(touch, 40))[$ - 1].canFind("⌕"), "at the bottom on touch");
}

@("tab_tree.key.searchOpensMatchingTabs")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto t = tree();
    foreach (dchar c; "viewer")
        assert(t.key(KeyEvent(Key.char_, c)));
    const shown = texts(t.build(SurfaceContext.init, 40));
    assert(shown.canFind("    ≡ nvim viewer.md"), "the match opens its tab");
    assert(!shown.canFind("    ❯ zsh"), "a tab without a match is gone");

    // Enter picks the first row: that tab.
    assert(t.confirm());
    assert(picked == [0, 0]);

    // Down to the pane, then Enter: it is focused.
    assert(t.key(KeyEvent(Key.down)));
    assert(t.confirm() && picked[1] == 4);

    // Backspace widens again.
    foreach (_; 0 .. 6)
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
    auto q = parseQuery(query);
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
        if (n.text.length && n.text[0 .. 3] == "⌕")
            assert(full.frames[i].rect.y == 29, "the search field on the last row");

    SurfaceContext pill = rail;
    pill.panelFull = false;
    assert(place(t.build(pill, 40), 40, 30, 0, 0, 1, 1, Place.top).bounds.height < 30);
}
