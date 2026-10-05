/**
The key guide by touch (`TKM6`, mockup K3): the commands under the leader as
tappable rows, the path as breadcrumbs, the recently used commands, and a
search across every command at the bottom, within thumb reach.

It reads the same table the keys resolve against (`KeyRouter.table`), so a
row does what its key does: a group row descends, a command row runs and
closes the guide. The breadcrumbs — `←`, `␣ leader`, the groups below it —
are tappable; Back and `Esc` pop one level, closing at the root.

A surface (`surfaces.Surface`) shown as a sheet above the extra keys. A level
or a result list taller than the room left (`TPG19`: a soft keyboard up, a
long group) shows a window onto its rows with how many lie above and below;
the marks are tappable, and a drag or the wheel scrolls it (`Scrollable`).
*/
module touch_guide;

import sparkles.input.events : Key, KeyEvent;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import chrome : band, label, row, uiLabel;
import keymap : Binding, Chord, KeyCommand, TermCommand, TermContext;
import surfaces : Placement, Scrollable, Surface, SurfaceContext;

/// Hit ids.
private enum size_t crumbHit = 0x6C00_0000, rowHit = 0x6C10_0000, recentHit = 0x6C20_0000,
    backHit = 0x6BFF_FFFF, moreAboveHit = 0x6C30_0000, moreBelowHit = 0x6C30_0001,
    searchHit = 0x6C30_0002;

/// The commands run from the guide most recently, newest first (shared by
/// every guide opened in this run).
private KeyCommand[] recent;

/// The touch key guide.
final class TouchGuide : Surface, Scrollable
{
    private immutable(Binding)[] table;
    private TermContext ctx;
    private Chord[] path; // the levels entered, the leader first
    private void delegate(KeyCommand) run;
    private char[] query;
    private Binding[] shown; // the rows built, for the hits
    private KeyCommand[] found; // the search results
    private size_t top; // the first list row shown, when they do not all fit
    private size_t fit; // how many list rows the last build showed
    private size_t listed; // how many list rows there were
    private size_t builtDepth, builtQuery; // what `top` belongs to
    private enum unknownRoom = int.max; // no area to fit: show every row

    /// A tap on the search field: the embedder brings up a keyboard to type
    /// into it (the phone's soft keyboard, which opening the guide hid).
    void delegate() @system onSearch;

    /// Opens at `root` (the leader's chord) over `table`; `run` executes a
    /// chosen command.
    this(immutable(Binding)[] table, TermContext ctx, Chord root,
        void delegate(KeyCommand) run) @safe pure nothrow
    {
        this.table = table;
        this.ctx = ctx;
        this.path = [root];
        this.run = run;
    }

    WidgetTree build(in SurfaceContext sctx, int cols) @safe
    {
        Builder b;
        uint[] lines;
        lines ~= crumbs(b, sctx);
        shown.length = 0;
        found.length = 0;
        // Another level or another query starts at its top.
        if (path.length != builtDepth || query.length != builtQuery)
            top = 0;
        builtDepth = path.length;
        builtQuery = query.length;

        // The rows left for the list: the area less the top border, the
        // breadcrumbs, the Recent row and the search field (`TPG19`).
        const per = sctx.targetRows > 1 ? sctx.targetRows : 1;
        const areaRows = sctx.cellH > 0 ? sctx.area.height / sctx.cellH : 0;
        const showRecent = !query.length && recent.length;
        const room = areaRows > 0 ? areaRows - 1 - per - (showRecent ? per : 0) - 1 : unknownRoom;

        if (query.length)
            lines ~= windowed(b, searchResults(b, sctx), room, per);
        else
        {
            lines ~= windowed(b, levelRows(b, sctx), room, per);
            if (showRecent)
            {
                uint[] chips = [uiLabel(b, "Recent", Slot.muted)];
                foreach (i, c; recent)
                    chips ~= chip(b, sctx, iconOf(c.cmd), descOf(c), recentHit + i);
                lines ~= b.add(Widget(kind: WidgetKind.row, children: chips, gap: 1,
                    alignY: Alignment.center));
            }
        }
        lines ~= b.add(Widget(kind: WidgetKind.panel,
            children: [uiLabel(b, query.length ? "⌕ " ~ query.idup : "⌕ Search all commands",
                query.length ? Slot.textPrimary : Slot.muted)],
            width: SizeSpec.grow(), slot: Slot.surfaceSunken, paintBackground: true,
            hitId: searchHit));
        return b.finish(band(b, lines));
    }

    Placement placement() const @safe => Placement.sheet;

    /// `Scrollable`: a drag or the wheel moves the list by whole rows.
    void scroll(int dy) @system
    {
        if (dy > 0)
            top += dy;
        else
            top = -dy >= top ? 0 : top + dy;
        // `windowed` clamps the far end on the next build.
    }

    /**
    `items` (each `per` rows tall) within `room` rows: all of them when they
    fit, else a window from `top` with a mark for what lies above and below —
    the marks take a row each, and a tap on one turns a page.
    */
    private uint[] windowed(ref Builder b, uint[] items, int room, int per) @safe
    {
        import std.conv : text;

        listed = items.length;
        // An unknown area (`room` from no area at all) shows everything; a
        // known one too small for the marks still shows a row.
        if (room == unknownRoom || items.length * per <= room)
        {
            top = 0;
            fit = items.length;
            return items;
        }
        fit = (room - 2) / per > 0 ? (room - 2) / per : 1;
        if (top + fit > items.length)
            top = items.length - fit;
        uint[] window;
        if (top)
            window ~= mark(b, text("↑ ", top, " more"), moreAboveHit);
        window ~= items[top .. top + fit];
        if (const below = items.length - top - fit)
            window ~= mark(b, text("↓ ", below, " more"), moreBelowHit);
        return window;
    }

    private static uint mark(ref Builder b, string text, size_t hit) @safe
        => b.add(Widget(kind: WidgetKind.row, children: [uiLabel(b, text, Slot.muted)],
            width: SizeSpec.grow(), hitId: hit));

    bool activate(size_t id) @system
    {
        if (id == searchHit)
        {
            if (onSearch !is null)
                onSearch();
            return false;
        }
        if (id == moreAboveHit || id == moreBelowHit)
        {
            scroll(id == moreAboveHit ? -cast(int) fit : cast(int) fit);
            return false;
        }
        if (id == backHit)
            return pop();
        if (id >= crumbHit && id < crumbHit + path.length)
        {
            path.length = id - crumbHit + 1;
            return false;
        }
        if (id >= recentHit && id < recentHit + recent.length)
            return execute(recent[id - recentHit]);
        if (id >= rowHit && id < rowHit + shown.length + found.length)
        {
            const i = id - rowHit;
            if (query.length)
                return execute(found[i]);
            const r = shown[i];
            if (r.group.length || r.cmd == TermCommand.none)
            {
                path ~= r.path[path.length];
                return false;
            }
            return execute(KeyCommand(r.cmd, r.arg));
        }
        return false;
    }

    bool confirm() @system
    {
        if (query.length && found.length)
            return execute(found[0]);
        return false;
    }

    void cancel() @system {}

    bool key(in KeyEvent k) @system
    {
        import std.utf : encode, strideBack;

        if (k.mods.ctrl || k.mods.alt || k.mods.super_)
            return false;
        switch (k.key)
        {
            case Key.escape:
            case Key.back:
                // One level up; at the root the overlay rows close the guide.
                if (query.length)
                {
                    query.length = 0;
                    return true;
                }
                if (path.length > 1)
                {
                    path.length--;
                    return true;
                }
                return false;
            case Key.backspace:
                if (query.length)
                    query.length -= strideBack(query, query.length);
                return true;
            case Key.char_:
                if (k.ch < 0x20)
                    return false;
                char[4] buf;
                query ~= buf[0 .. encode(buf, k.ch)];
                return true;
            default:
                return false;
        }
    }

    /// The path, as the user would type it: `␣ p v`.
    string pathText() const @safe
    {
        string s;
        foreach (i, c; path)
            s ~= (i ? " " : "") ~ chordText(c, i == 0);
        return s;
    }

    private bool pop() @safe pure nothrow
    {
        if (path.length > 1)
        {
            path.length--;
            return false;
        }
        return true; // at the root: close
    }

    private bool execute(KeyCommand c) @system
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        const at = recent.countUntil(c);
        if (at >= 0)
            recent = recent.remove(at);
        recent = c ~ recent;
        if (recent.length > 3)
            recent.length = 3;
        run(c);
        return true;
    }

    /// What the guide's rows call `c` ("split right"), not its config name
    /// (`splitRight`) — the Recent chips repeat a row the user tapped.
    private string descOf(KeyCommand c) const @safe pure nothrow
    {
        foreach (ref r; table)
            if (r.cmd == c.cmd && r.desc.length)
                return r.desc;
        return nameOf(c.cmd);
    }

    private uint crumbs(ref Builder b, in SurfaceContext sctx) @safe
    {
        uint[] parts = [chip(b, sctx, "←", null, backHit)];
        foreach (i, c; path)
        {
            if (i)
                parts ~= label(b, "›", Slot.muted);
            parts ~= chip(b, sctx, i == 0 ? "␣" : null, i == 0 ? "leader" : groupName(i),
                crumbHit + i, current: i + 1 == path.length);
        }
        return b.add(Widget(kind: WidgetKind.row, children: parts, gap: 1,
            alignY: Alignment.center));
    }

    private uint[] levelRows(ref Builder b, in SurfaceContext sctx) @safe
    {
        import sparkles.base.buffer : SharedBuffer;
        import keymap : bindingsAt;

        SharedBuffer!(Binding, 64) rows;
        (() @trusted => bindingsAt(rows, table, ctx, path))();
        uint[] lines;
        foreach (ref r; rows[])
        {
            const isGroup = r.group.length || r.depth > path.length + 1;
            const key = chordText(r.path[path.length], false);
            const name = isGroup ? "+" ~ (r.group.length ? r.group : "more") : r.desc;
            lines ~= entry(b, sctx, key, isGroup ? "›" : iconOf(r.cmd), name, null,
                rowHit + shown.length);
            shown ~= r;
        }
        if (!lines.length)
            lines ~= uiLabel(b, "Nothing here.", Slot.muted);
        return lines;
    }

    private uint[] searchResults(ref Builder b, in SurfaceContext sctx) @safe
    {
        import std.algorithm.sorting : sort;

        import tab_tree : fuzzyScore;

        // Ranked by `sparkles:fuzzy` over the description and the command's
        // name, best first; ties keep the table's order.
        static struct Hit
        {
            size_t row;
            long score;
        }

        Hit[] hits;
        bool[TermCommand] seen;
        foreach (i, ref r; table)
        {
            if (r.cmd == TermCommand.none || r.group.length || (r.cmd in seen) !is null)
                continue;
            const sd = fuzzyScore(query, r.desc), sn = fuzzyScore(query, nameOf(r.cmd));
            if (!sd && !sn)
                continue;
            seen[r.cmd] = true;
            hits ~= Hit(i, sd > sn ? sd : sn);
        }
        hits.sort!((a, b) => a.score > b.score || a.score == b.score && a.row < b.row);

        uint[] lines;
        foreach (hit; hits)
        {
            const r = table[hit.row];
            string keys;
            foreach (i; 0 .. r.depth)
                keys ~= (i ? " " : "") ~ chordText(r.path[i], r.path[i] == path[0]);
            lines ~= entry(b, sctx, null, iconOf(r.cmd), r.desc, keys, rowHit + found.length);
            found ~= KeyCommand(r.cmd, r.arg);
        }
        if (!lines.length)
            lines ~= uiLabel(b, "No command matches.", Slot.muted);
        return lines;
    }

    private string groupName(size_t depth) const @safe
    {
        foreach (ref r; table)
            if (r.group.length && r.depth == depth + 1)
            {
                bool same = true;
                foreach (i; 0 .. depth + 1)
                    same &= r.path[i] == path[i];
                if (same)
                    return r.group;
            }
        return chordText(path[depth], false);
    }

    private uint entry(ref Builder b, in SurfaceContext sctx, string key, string icon,
        string name, string where, size_t hit) @safe
    {
        uint[] parts;
        if (key.length)
            parts ~= label(b, key, Slot.accentPrimary, bold: true);
        parts ~= label(b, icon, Slot.muted);
        parts ~= uiLabel(b, name, Slot.textPrimary);
        if (where.length)
            parts ~= label(b, where, Slot.muted);
        return b.add(Widget(kind: WidgetKind.row, children: parts, gap: 1,
            width: SizeSpec.grow(),
            height: sctx.targetRows > 1 ? SizeSpec.fixed(sctx.targetRows) : SizeSpec.fit_,
            hitId: hit));
    }

    // A chip: `icon` in the cell font, which carries every icon, and `text` in
    // the interface face; either may be empty.
    private uint chip(ref Builder b, in SurfaceContext sctx, string icon, string text,
        size_t hit, bool current = false) @safe
    {
        import sparkles.ui.geometry : Insets;
        import sparkles.ui.style : BorderStyle, Decoration;

        return b.add(Widget(kind: WidgetKind.panel,
            children: [chipContent(b, icon, text, current)],
            padding: Insets(0, 1, 0, 1),
            height: sctx.targetRows > 1 ? SizeSpec.fixed(sctx.targetRows) : SizeSpec.fit_,
            hitId: hit, slot: Slot.surfaceRaised, paintBackground: true,
            alignY: Alignment.center,
            decoration: Decoration(borderRadius: 16, drawHeight: 32)));
    }

    private static uint chipContent(ref Builder b, string icon, string text, bool current) @safe
    {
        const slot = current ? Slot.accentPrimary : Slot.textPrimary;
        uint[] parts;
        if (icon.length)
            parts ~= label(b, icon, slot, bold: current);
        if (text.length)
            parts ~= uiLabel(b, text, slot, bold: current);
        return parts.length == 1 ? parts[0]
            : b.add(Widget(kind: WidgetKind.row, children: parts, gap: 1,
                alignY: Alignment.center));
    }
}

/// A chord as the guide shows it: `v`, `Ctrl+Shift+T`; the leader as `␣`.
private string chordText(in Chord c, bool isLeader) @safe
{
    import sparkles.input.events : unparseChord;

    if (isLeader)
        return "␣";
    if (c.chEnd)
    {
        import std.conv : text;

        return text(c.ch, "-", c.chEnd);
    }
    return unparseChord(c);
}

/// A command's name for the Recent chips.
private string nameOf(TermCommand c) @safe pure nothrow
{
    import keymap : commandName;

    return commandName(c);
}

/// A command's icon (K3).
string iconOf(TermCommand c) @safe pure nothrow @nogc
{
    switch (c)
    {
        case TermCommand.splitRight: return "◫";
        case TermCommand.splitDown: return "⬓";
        case TermCommand.zoomPane: return "⤢";
        case TermCommand.closePane, TermCommand.closeTab: return "×";
        case TermCommand.focusLeft, TermCommand.focusRight, TermCommand.focusUp,
            TermCommand.focusDown: return "✥";
        case TermCommand.resizeLeft, TermCommand.resizeRight, TermCommand.resizeUp,
            TermCommand.resizeDown: return "⇔";
        case TermCommand.newTab: return "＋";
        case TermCommand.tabTree: return "☰";
        case TermCommand.goToTab: return "#";
        case TermCommand.copy: return "⧉";
        case TermCommand.paste: return "⎘";
        case TermCommand.toggleExtraKeys: return "⌨";
        case TermCommand.showGuide: return "?";
        case TermCommand.openAbout: return "ⓘ";
        case TermCommand.openLogs: return "≣";
        case TermCommand.openNotifications: return "◉";
        case TermCommand.showCredits: return "©";
        case TermCommand.openSettings: return "⚙";
        default: return "·";
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import keymap : defaultLeader, KeysConfig, leaderChord, terminalBindings;

    private KeyCommand[] ran;

    private TouchGuide guide() @safe
    {
        string[] w;
        const leader = leaderChord(defaultLeader, w);
        ran = null;
        recent = null;
        return new TouchGuide(terminalBindings(leader, KeysConfig.init, w), TermContext.init,
            leader, (KeyCommand c) { ran ~= c; });
    }

    private const(char)[][] texts(in WidgetTree t) @safe
    {
        const(char)[][] r;
        foreach (ref n; t.nodes)
            if (n.text.length)
                r ~= n.text;
        return r;
    }

    private size_t hitOf(TouchGuide g, string name) @system
    {
        import chrome : place, Place;

        auto l = place(g.build(SurfaceContext.init, 60), 60, 30, 0, 0, 1, 1, Place.top);
        foreach (ref t; l.hits)
            foreach (ref n; l.tree.nodes)
                if (n.hitId == t.hitId)
                    foreach (c; n.children)
                        if (l.tree.nodes[c].text == name)
                            return t.hitId;
        return 0;
    }
}

@("touch_guide.descendRunAndBack")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto g = guide();
    assert(g.pathText == "␣");
    auto shown = texts(g.build(SurfaceContext.init, 60));
    assert(shown.canFind("+pane") && shown.canFind("+tab"), "the leader's groups");

    // Tap `+pane`: one level down; the crumb names it.
    assert(!g.activate(hitOf(g, "+pane")));
    assert(g.pathText == "␣ p");
    shown = texts(g.build(SurfaceContext.init, 60));
    assert(shown.canFind("split right") && shown.canFind("pane"));

    // Tap `split right`: it runs and the guide closes.
    assert(g.activate(hitOf(g, "split right")));
    assert(ran.length == 1 && ran[0].cmd == TermCommand.splitRight);
    const recentShown = texts(g.build(SurfaceContext.init, 60));
    assert(recentShown.canFind("◫") && recentShown.canFind("split right"),
        "a Recent chip, described");

    // Back pops a level; at the root it declines (the overlay row closes).
    assert(g.key(KeyEvent(Key.back)));
    assert(g.pathText == "␣");
    assert(!g.key(KeyEvent(Key.back)));
}

@("touch_guide.searchAcrossLevels")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto g = guide();
    foreach (dchar c; "zoom")
        assert(g.key(KeyEvent(Key.char_, c)));
    const shown = texts(g.build(SurfaceContext.init, 60));
    assert(shown.canFind("zoom") && shown.canFind("␣ p z"), "the full key path");
    assert(g.confirm() && ran[0].cmd == TermCommand.zoomPane);
}

@("touch_guide.searchIsFuzzyAndRanked")
@system unittest
{
    // Not a substring of anything: "sprt" finds "split right" by its letters,
    // ranked first, and Enter runs the best match.
    auto g = guide();
    foreach (dchar c; "sprt")
        assert(g.key(KeyEvent(Key.char_, c)));
    cast(void) g.build(SurfaceContext.init, 60);
    assert(g.confirm() && ran[$ - 1].cmd == TermCommand.splitRight);
}

@("touch_guide.aTallLevelScrollsInsteadOfOverlapping")
@system unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.ui.geometry : Rect;

    import chrome : place, Place;

    // The pane group (12 commands) in a 14-row area, two rows a command: it
    // cannot all show, and nothing may be drawn over anything else (`TPG19`).
    auto g = guide();
    assert(!g.activate(hitOf(g, "+pane")));
    SurfaceContext ctx = {area: Rect(0, 0, 60, 14), cellW: 1, cellH: 1, targetRows: 2};

    auto layout() => place(g.build(ctx, 60), 60, 14, 0, 0, 1, 1, Place.bottom);

    // What is laid out: the texts under each placed target (a row cut from
    // the window is built, but never placed).
    const(char)[][] targets(L)(in L l)
    {
        const(char)[][] r;
        foreach (ref t; l.hits)
            foreach (ref n; l.tree.nodes)
                if (n.hitId == t.hitId)
                    foreach (c; n.children)
                        r ~= l.tree.nodes[c].text;
        return r;
    }

    auto l = layout();
    assert(l.bounds.height <= 14, "the sheet stays within its area");
    foreach (i, ref a; l.hits)
        foreach (ref c; l.hits[i + 1 .. $])
            assert(a.rect.y + a.rect.height <= c.rect.y || c.rect.y + c.rect.height <= a.rect.y
                || a.rect.x + a.rect.width <= c.rect.x || c.rect.x + c.rect.width <= a.rect.x,
                "two targets overlap");
    auto shown = targets(l);
    assert(shown.canFind("split right") && !shown.canFind("close pane"));
    assert(shown.canFind!(t => t.length > 2 && t[0 .. 3] == "↓"), "what lies below is counted");

    // A tap on the mark (or a drag) turns the page: the end of the list shows.
    assert(!g.activate(moreBelowHit));
    assert(!g.activate(moreBelowHit));
    shown = targets(layout());
    assert(shown.canFind("close pane") && !shown.canFind("split right"));
}
