/**
The key guide by touch (`TKM6`, mockup K3): the commands under the leader as
tappable rows, the path as breadcrumbs, the recently used commands, and a
search across every command at the bottom, within thumb reach.

It reads the same table the keys resolve against (`KeyRouter.table`), so a
row does what its key does: a group row descends, a command row runs and
closes the guide. The breadcrumbs — `←`, `␣ leader`, the groups below it —
are tappable; Back and `Esc` pop one level, closing at the root.

A surface (`surfaces.Surface`) shown as a sheet above the extra keys.
*/
module touch_guide;

import sparkles.input.events : Key, KeyEvent;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;

import chrome : band, label, row;
import keymap : Binding, Chord, KeyCommand, TermCommand, TermContext;
import surfaces : Placement, Surface, SurfaceContext;

/// Hit ids.
private enum size_t crumbHit = 0x6C00_0000, rowHit = 0x6C10_0000, recentHit = 0x6C20_0000,
    backHit = 0x6BFF_FFFF;

/// The commands run from the guide most recently, newest first (shared by
/// every guide opened in this run).
private KeyCommand[] recent;

/// The touch key guide.
final class TouchGuide : Surface
{
    private immutable(Binding)[] table;
    private TermContext ctx;
    private Chord[] path; // the levels entered, the leader first
    private void delegate(KeyCommand) run;
    private char[] query;
    private Binding[] shown; // the rows built, for the hits
    private KeyCommand[] found; // the search results

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
        if (query.length)
            lines ~= searchResults(b, sctx);
        else
        {
            lines ~= levelRows(b, sctx);
            if (recent.length)
            {
                uint[] chips = [label(b, "Recent", Slot.muted)];
                foreach (i, c; recent)
                    chips ~= chip(b, sctx, iconOf(c.cmd) ~ " " ~ nameOf(c.cmd), recentHit + i);
                lines ~= row(b, chips);
            }
        }
        lines ~= b.add(Widget(kind: WidgetKind.panel,
            children: [label(b, query.length ? "⌕ " ~ query.idup : "⌕ Search all commands",
                query.length ? Slot.textPrimary : Slot.muted)],
            width: SizeSpec.grow(), slot: Slot.surfaceSunken, paintBackground: true));
        return b.finish(band(b, lines));
    }

    Placement placement() const @safe => Placement.sheet;

    bool activate(size_t id) @system
    {
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

    private uint crumbs(ref Builder b, in SurfaceContext sctx) @safe
    {
        uint[] parts = [chip(b, sctx, "←", backHit)];
        foreach (i, c; path)
        {
            if (i)
                parts ~= label(b, "›", Slot.muted);
            string name = i == 0 ? "␣ leader" : groupName(i);
            parts ~= chip(b, sctx, name, crumbHit + i, current: i + 1 == path.length);
        }
        return row(b, parts);
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
            lines ~= label(b, "Nothing here.", Slot.muted);
        return lines;
    }

    private uint[] searchResults(ref Builder b, in SurfaceContext sctx) @safe
    {
        import std.algorithm.searching : canFind;
        import std.uni : toLower;

        const q = query.idup.toLower;
        uint[] lines;
        bool[TermCommand] seen;
        foreach (ref r; table)
        {
            if (r.cmd == TermCommand.none || r.group.length || (r.cmd in seen) !is null)
                continue;
            if (!r.desc.toLower.canFind(q) && !nameOf(r.cmd).toLower.canFind(q))
                continue;
            seen[r.cmd] = true;
            string keys;
            foreach (i; 0 .. r.depth)
                keys ~= (i ? " " : "") ~ chordText(r.path[i], r.path[i] == path[0]);
            lines ~= entry(b, sctx, null, iconOf(r.cmd), r.desc, keys, rowHit + found.length);
            found ~= KeyCommand(r.cmd, r.arg);
        }
        if (!lines.length)
            lines ~= label(b, "No command matches.", Slot.muted);
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
        parts ~= label(b, name, Slot.textPrimary);
        if (where.length)
            parts ~= label(b, where, Slot.muted);
        return b.add(Widget(kind: WidgetKind.row, children: parts, gap: 1,
            width: SizeSpec.grow(),
            height: sctx.targetRows > 1 ? SizeSpec.fixed(sctx.targetRows) : SizeSpec.fit_,
            hitId: hit));
    }

    private uint chip(ref Builder b, in SurfaceContext sctx, string text, size_t hit,
        bool current = false) @safe
    {
        import sparkles.ui.geometry : Insets;
        import sparkles.ui.style : BorderStyle, Decoration;

        return b.add(Widget(kind: WidgetKind.panel,
            children: [label(b, text, current ? Slot.accentPrimary : Slot.textPrimary,
                bold: current)],
            padding: Insets(0, 1, 0, 1),
            height: sctx.targetRows > 1 ? SizeSpec.fixed(sctx.targetRows) : SizeSpec.fit_,
            hitId: hit, slot: Slot.surfaceRaised, paintBackground: true,
            decoration: Decoration(borderRadius: 12)));
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
        case TermCommand.newTab: return "＋";
        case TermCommand.tabTree: return "☰";
        case TermCommand.goToTab: return "#";
        case TermCommand.copy: return "⧉";
        case TermCommand.paste: return "⎘";
        case TermCommand.toggleExtraKeys: return "⌨";
        case TermCommand.showGuide: return "?";
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
    assert(texts(g.build(SurfaceContext.init, 60)).canFind("◫ splitRight"), "a Recent chip");

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
