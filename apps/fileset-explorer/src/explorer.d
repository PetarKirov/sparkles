/**
The fileset explorer as a `runApp` component (`FXU1`–`FXU9`).

The screen is a title line, the query editor, a dock and a key hint line.
The dock holds the member tree on the left and, on the right, one tabbed
group: Stats, Help and Export. Every edit of the query re-parses and
re-resolves it and redraws everything from the new result (`FXU1`).
*/
module explorer;

import std.algorithm.comparison : max, min;
import std.conv : text;
import std.format : format;

import sparkles.base.text.grapheme : visibleWidth;
import sparkles.build_primitives.fileset.fso : FsoKind;
import sparkles.build_primitives.fileset.query : Span, Token, TokenKind;
import sparkles.input : Event, isEndOfInput, Key, KeyEvent, match, Mods, PasteEvent, Point,
    PointerAction, PointerButton, PointerEvent, WheelEvent;
import sparkles.ui.components.chrome : tabStrip;
import sparkles.ui.hit_ids : HitBlock;
import sparkles.ui.components.dock : DockAxis, DockContainer, DockKind, DockLayout, PaneId,
    RouteKind;
import sparkles.ui.components.editor : caretColumnOf, editorLineSpans, EditorViewOptions;
import sparkles.ui.components.tree_view : collapseOrUp, measureContent, TreeStep, TreeViewState,
    treeActivate = activate, viewSlice;
import sparkles.ui.components.tree_widget : flatten, TreeData, TreeGlyphs;
import sparkles.ui.editor.field : EditorField;
import sparkles.ui.geometry : Insets, Rect, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;

import evaluate : autoIdBytes, evaluate, humanBytes, Outcome, Root;
import help : helpSource, namedTrees, runFileset, TryBlock, tryBlocks, TryOutcome;
import member_tree : buildTree, Item, syncFolders;
import sparkles.source_view.markdown : MdViewOptions, OverflowPolicy, viewMarkdownInto, WrapOverflow;
import sparkles.syntax.md.model : MdDoc;
import sparkles.ui.layout : Frame;

/// The dock's panes.
enum Pane : PaneId
{
    tree = 1,   ///
    stats = 2,  ///
    help = 3,   ///
    export_ = 4, ///
}

/// Where the keyboard goes.
enum Focus : ubyte
{
    query, ///
    tree,  ///
    side,  /// the right tab group
}

/// The explorer.
struct ExplorerApp
{
    Root dir;               /// the directory given on the command line
    Root root;              /// what queries resolve against: `dir`, or a tutorial's tree
    EditorField query;      /// the expression being written
    Outcome outcome;        /// of the last query that parsed
    Outcome shown;          /// what the panes show: the last good result (invariant 3)
    TreeData!Item tree;     /// its members
    TreeViewState!string tv; /// cursor, scroll and disclosure, by path
    DockContainer dock;     ///
    Focus focus;            ///
    bool idsRequested;      /// `i` asked for the ids of a large fileset

    private uint tabsNode;  // the right group's node in the dock

    // The help (`FXU7`, `FXT`): the page, its try blocks and named trees,
    // where it is scrolled to, which block is selected, and what each run gave.
    MdDoc helpDoc;                  ///
    TryBlock[] tries;               ///
    string[string] trees;           ///
    int helpTop;                    /// the help's first shown row
    size_t trySel;                  /// the selected try block
    TryOutcome[size_t] tryResults;  /// by the block's `at`
    private size_t lastTab;         // the tab F1 returns to
    private Focus lastFocus;        // and the focus
    private TryHit[] tryHits;       // where this frame drew each ▶ (`paint`)
    private int[size_t] tryRows;    // each try block's row in the help's content

    /// The base of the ▶ hit ids: `tryHitBase + at`.
    enum size_t tryHitBase = 1 << 24;

    /// Starts on `source` beneath `dir`.
    this(Root dir, string source)
    {
        this.dir = dir;
        this.root = dir;
        query = EditorField.make(source);
        tv.open = typeof(tv.open).allOpen;
        tv.chromeRows = 0;
        tv.headerRows = 0;
        dock.layout = initialLayout(tabsNode, helpLeaf);
        dock.focused = Pane.tree;
        loadHelp();
        refresh();
    }

    // Parses the help page; without the markdown grammar it stays its text.
    private void loadHelp() @system
    {
        import sparkles.syntax.md.model : extractMarkdown;
        import sparkles.syntax.ts.registry : GrammarRegistry;

        auto registry = GrammarRegistry.fromEnvironment();
        helpDoc = extractMarkdown(registry, helpSource);
        tries = tryBlocks(helpDoc);
        trees = namedTrees(helpDoc);
    }

    /// Runs try block `i` (`FXT3`): its query goes into the editor, resolved
    /// against its named tree, and its result under the block.
    void runTry(size_t i)
    {
        import std.string : stripRight;

        if (i >= tries.length)
            return;
        trySel = i;
        const t = tries[i];
        tryResults[t.at] = runFileset(t, trees, dir);
        query = EditorField.make(t.input.stripRight("\n"));
        if (t.tree !is null && t.tree in trees)
            root = Root(literal: trees[t.tree], name: t.tree);
        else
            root = dir;
        refresh();
    }

    /// Whether the Help tab is the one showing.
    bool helpShown() const @safe
        => dock.layout.nodes[tabsNode].children[dock.layout.nodes[tabsNode].active]
            == helpLeaf;

    private uint helpLeaf;

    /// Shows the help, or goes back to where F1 was pressed (`FXU7`).
    void toggleHelp()
    {
        auto g = &dock.layout.nodes[tabsNode];
        if (helpShown)
        {
            g.active = cast(uint) lastTab;
            focus = lastFocus;
            return;
        }
        lastTab = g.active;
        lastFocus = focus;
        foreach (i, c; g.children)
            if (c == helpLeaf)
                g.active = cast(uint) i;
        focus = Focus.side;
    }

    /// Records where this frame drew each ▶, for a click to find (`FXT2`).
    void paint(H)(ref H h, in WidgetTree t, in Frame[] frames)
    {
        tryHits.length = 0;
        foreach (i, ref n; t.nodes)
            if (n.hitId >= tryHitBase && n.hitId < tryHitBase + helpSource.length && i < frames.length)
                tryHits ~= TryHit(frames[i].rect, n.hitId - tryHitBase);
        const r = paneRect(Pane.help);
        foreach (ref hit; tryHits)
            tryRows[hit.at] = hit.rect.y - (r.y + dockTop) + helpTop;
    }

    /// Re-evaluates the query and rebuilds the tree, keeping what was open.
    void refresh()
    {
        outcome = evaluate(root, query.text, idsRequested);
        idsRequested = false;
        if (!outcome.failed)
        {
            shown = outcome;
            tree = buildTree(shown.found.members);
        }
        reflatten();
    }

    private void reflatten()
    {
        auto open = tv.open;
        syncFolders(tree, (string p) => open.isOpen(p));
        auto data = &tree;
        tv.rows = flatten(tree, (uint n) @safe => open.isOpen(data.nodes[n].value.path));
        measureContent(tv, tree);
        tv.clamp();
    }

    private string keyOf(uint n) @safe => tree.nodes[n].value.path;

    // ---- the frame ------------------------------------------------------

    /// The frame.
    WidgetTree view(H)(ref H h)
    {
        const size = h.size;
        auto b = Builder();

        const title = b.add(Widget(kind: WidgetKind.rich, width: SizeSpec.grow(), spans: [
            TextSpan(" fileset explorer ", Slot.chromeAccent, TextStyle(bold: true)),
            TextSpan(root.inMemory ? "tutorial tree `" ~ root.name ~ "` (Esc returns)" : dir.dir,
                root.inMemory ? Slot.warn : Slot.muted),
        ]));

        // The query: its lines up to a third of the screen, and the status.
        const lines = query.state.text.lineCount;
        const room = max(1, size.height / 3 - 3);
        const queryRows = cast(int) min(lines, room);
        const queryPane = panel(b, "query", queryRows + 1,
            queryLines(b, queryRows) ~ statusLine(b), focus == Focus.query);

        // The dock fills the rest.
        const dockRows = max(4, size.height - 1 - (queryRows + 3) - 1);
        dockY = 1 + queryRows + 3;
        const stats = statsLines();
        arrangeDock(size.width, dockRows, stats);
        const dockView = b.add(Widget(kind: WidgetKind.column, width: SizeSpec.grow(),
            height: SizeSpec.fixed(dockRows), children: [renderNode(b, dock.layout.root, stats)]));

        const footer = b.add(Widget(kind: WidgetKind.text, slot: Slot.muted, text: hints()));
        return b.finish(b.add(Widget(kind: WidgetKind.column, width: SizeSpec.grow(),
            children: [title, queryPane, dockView, footer])));
    }

    private string hints() const @safe pure nothrow
    {
        final switch (focus)
        {
            case Focus.query:
                return " type to query live · | & - ( ) # · Tab tree · F1 help · Esc quit";
            case Focus.tree:
                return " ↑↓ move · ←→ close/open · ⏎ toggle · o/c all · i ids · Tab side · F1 help · Esc quit";
            case Focus.side:
                return " ←→ tabs · ↑↓ scroll · Tab query · F1 help · Esc quit";
        }
    }

    // The query's lines, highlighted (`FXU4`), the caret left to the host (`FXU3`).
    private uint[] queryLines(ref Builder b, int rows)
    {
        import sparkles.ui.components.editor : scrollToPrimary;

        EditorViewOptions o;
        o.hostCursor = true;
        o.caretVisible = focus == Focus.query;
        const text_ = query.state.text;
        const lineCount = text_.lineCount;
        const first = scrollToPrimary(query.state, firstLine, rows);
        firstLine = first;
        const caretLine = text_.lineOf(query.state.selection.primary.head);
        uint[] out_;
        foreach (line; first .. min(lineCount, first + rows))
        {
            auto spans = highlight(editorLineSpans(query.state, line, o), outcome.query.tokens,
                outcome.failed ? errorSpan() : Span(size_t.max, size_t.max));
            const prompt = b.add(Widget(kind: WidgetKind.text, text: line == 0 ? "❯ " : "  ",
                slot: Slot.accentPrimary));
            auto w = Widget(kind: WidgetKind.rich, spans: spans, width: SizeSpec.grow());
            if (o.caretVisible && line == caretLine)
                w.caretColumn = caretColumnOf(query.state);
            out_ ~= b.add(Widget(kind: WidgetKind.row, width: SizeSpec.grow(),
                children: [prompt, b.add(w)]));
        }
        if (lineCount == 0 || text_.length == 0)
        {
            auto w = Widget(kind: WidgetKind.rich, width: SizeSpec.grow(),
                spans: [TextSpan("❯ ", Slot.accentPrimary),
                    TextSpan("a fileset — try **/*.d - **/*_test.d", Slot.muted)]);
            if (o.caretVisible)
                w.caretColumn = 2;
            out_ = [b.add(w)];
        }
        return out_;
    }

    private size_t firstLine;

    // The bytes the error is about: its token, or the end of the query.
    private Span errorSpan() const @safe pure nothrow
    {
        const at = outcome.error.offset;
        foreach (ref t; outcome.query.tokens)
            if (at >= t.span.start && at < t.span.end)
                return t.span;
        return Span(at, at + 1);
    }

    // The status line: the error under its place, or the canonical form.
    private uint statusLine(ref Builder b)
    {
        import sparkles.build_primitives.fileset.query : canonical;

        if (outcome.failed)
        {
            const e = outcome.error;
            // The column of the error in its line, after the two-cell prompt.
            const src = query.text;
            size_t lineStart;
            foreach (i; 0 .. min(e.offset, src.length))
                if (src[i] == '\n')
                    lineStart = i + 1;
            const col = 2 + visibleWidth(src[lineStart .. min(e.offset, src.length)]);
            char[] pad;
            pad.length = col;
            pad[] = ' ';
            return b.add(Widget(kind: WidgetKind.rich, width: SizeSpec.grow(), spans: [
                TextSpan(pad.idup ~ "^ ", Slot.error), TextSpan(e.message, Slot.error),
                TextSpan(outcome.query.ok ? "" : "  (showing the last result)", Slot.muted),
            ]));
        }
        return b.add(Widget(kind: WidgetKind.rich, width: SizeSpec.grow(), spans: [
            TextSpan("  = ", Slot.muted), TextSpan(canonical(outcome.query), Slot.code),
        ]));
    }

    // ---- the dock --------------------------------------------------------

    private static DockLayout initialLayout(out uint tabs, out uint helpLeaf)
    {
        DockLayout l;
        const t = l.addLeaf(Pane.tree, minExtent: 20);
        l.nodes[t].title = "members";
        l.nodes[t].headerExtent = 1;
        const s = l.addLeaf(Pane.stats);
        l.nodes[s].title = "Stats";
        helpLeaf = l.addLeaf(Pane.help);
        l.nodes[helpLeaf].title = "Help";
        tabs = l.addTabs([s, helpLeaf]);
        l.root = l.addSplit(DockAxis.horizontal, [t, tabs]);
        return l;
    }

    /// Sizes the right group to its content when the tree still fits beside
    /// it, else gives the tree at least half (`FXU5`), and arranges the dock.
    private void arrangeDock(int width, int rows, in string[2][] stats)
    {
        int widest;
        foreach (ref kv; stats)
            widest = max(widest, cast(int)(statsKeyWidth + visibleWidth(kv[1])));
        const want = widest + 2; // a column of padding each side
        const treeNeeds = treeWidth() + 1;
        const fits = width - want >= treeNeeds;
        dock.layout.nodes[tabsNode].extent = max(10, fits ? want : min(want, max(width - treeNeeds, width / 2)));
        if (helpShown) // the help reads at half the width at least
            dock.layout.nodes[tabsNode].extent = max(dock.layout.nodes[tabsNode].extent, min(width / 2, 90));
        dock.arrange(Rect(0, 0, width, rows));
        foreach (ref f; dock.frames.panes)
            if (f.pane == Pane.tree)
            {
                tv.width = f.rect.width;
                tv.resize(f.rect.height);
            }
    }

    private uint renderNode(ref Builder b, uint idx, in string[2][] stats)
    {
        const n = dock.layout.nodes[idx];
        if (n.kind == DockKind.leaf)
            return paneView(b, cast(Pane) n.pane, n.title, n.headerExtent > 0, n.extent, stats);
        if (n.kind == DockKind.tabs)
        {
            string[] labels;
            foreach (ch; n.children)
                labels ~= dock.layout.nodes[ch].title;
            const strip = tabStrip(b, labels, n.active, HitBlock.init);
            const shown = n.children[n.active < n.children.length ? n.active : 0];
            const pane = cast(Pane) dock.layout.nodes[shown].pane;
            return b.add(Widget(kind: WidgetKind.column, children: [strip,
                paneView(b, pane, null, false, 0, stats)],
                width: n.extent > 0 ? SizeSpec.fixed(n.extent) : SizeSpec.grow()));
        }
        uint[] kids;
        foreach (i, ch; n.children)
        {
            if (i)
                kids ~= b.add(Widget(kind: WidgetKind.box, slot: Slot.border, paintBackground: true,
                    width: SizeSpec.fixed(1), height: SizeSpec.grow()));
            kids ~= renderNode(b, ch, stats);
        }
        return b.add(Widget(kind: WidgetKind.row, children: kids, width: SizeSpec.grow(),
            height: SizeSpec.grow()));
    }

    private Rect paneRect(Pane p) const @safe
    {
        foreach (ref f; dock.frames.panes)
            if (f.pane == p)
                return f.rect;
        return Rect.init;
    }

    private uint paneView(ref Builder b, Pane pane, string title, bool header, int extent,
        in string[2][] stats)
    {
        const r = paneRect(pane);
        uint content;
        final switch (pane)
        {
            case Pane.tree: content = treeView(b); break;
            case Pane.stats: content = statsView(b, stats[0 .. min(stats.length, max(0, r.height))]); break;
            case Pane.help: content = helpView(b, r); break;
            case Pane.export_: content = b.add(Widget(kind: WidgetKind.column)); break;
        }
        // The dock's own geometry, clipped: a long row never spills into a neighbour.
        const body_ = b.add(Widget(kind: WidgetKind.column, children: [content], width: SizeSpec.fixed(max(0, r.width)),
            height: SizeSpec.fixed(max(0, r.height)), clipX: true));
        if (!header)
            return body_;
        const focused = (focus == Focus.tree && pane == Pane.tree) || (focus == Focus.side && pane != Pane.tree);
        const head = b.add(Widget(kind: WidgetKind.text, width: SizeSpec.grow(),
            text: text(" ", shown.found.members.length, " ",
                shown.found.members.length == 1 ? "member" : "members"),
            slot: focused ? Slot.chromeFocused : Slot.chrome, paintBackground: true,
            textStyle: TextStyle(bold: focused)));
        return b.add(Widget(kind: WidgetKind.column, children: [head, body_],
            width: SizeSpec.fixed(max(0, r.width)), clipX: true));
    }

    private uint treeView(ref Builder b)
    {
        if (tree.nodes.length == 0)
            return b.add(Widget(kind: WidgetKind.text, slot: Slot.muted,
                text: shown.resolved ? " (no members)" : ""));
        // The folder glyph is the disclosure marker (hue `XPL6`).
        const glyphs = TreeGlyphs(closed: "", open: "", leaf: "");
        auto open = tv.open;
        auto data = &tree;
        return viewSlice(b, tree, tv, (uint n) @safe => open.isOpen(data.nodes[n].value.path), glyphs);
    }

    // The widest visible row of the tree as drawn: guides, the folder or file
    // glyph, the name, and the badge after a space.
    private int treeWidth() const @safe
    {
        int widest;
        foreach (ref r; tv.rows)
        {
            const v = tree.nodes[r.node].value;
            widest = max(widest, cast(int)(r.depth * 3 + 3 + 2 + visibleWidth(v.label) + 1 + visibleWidth(v.badge)));
        }
        return widest;
    }

    // ---- help ---------------------------------------------------------------

    // The help page in a viewport scrolled to `helpTop` (`FXU7`).
    private uint helpView(ref Builder b, Rect r)
    {
        import std.algorithm.iteration : splitter;

        uint content;
        if (helpDoc.root.children.length == 0)
        {
            // No markdown grammar here: the page as its text.
            uint[] rows;
            foreach (line; helpSource.splitter('\n'))
                rows ~= b.add(Widget(kind: WidgetKind.text, text: line, slot: Slot.docs));
            content = b.add(Widget(kind: WidgetKind.column, children: rows));
        }
        else
        {
            MdViewOptions o;
            o.maxWidth = max(10, r.width - 2);
            o.tableOverflow = OverflowPolicy(WrapOverflow());
            o.tryRunners = ["fileset"];
            o.tryHits = HitBlock(tryHitBase, helpSource.length + 1); // by the fence's source offset
            o.tryResult = (ref Builder bb, size_t at) => resultView(bb, at);
            content = viewMarkdownInto(b, helpDoc, o);
        }
        auto vp = Widget(kind: WidgetKind.column, children: [content], clipX: true, clipY: true,
            width: SizeSpec.fixed(max(0, r.width)), height: SizeSpec.fixed(max(0, r.height)),
            padding: Insets(0, 1, 0, 1));
        vp.childOffset = Point(0, helpTop);
        return b.add(vp);
    }

    // What shows under try block `at`: its result, checked against its
    // expected fence, or, for the selected one, how to run it.
    private uint resultView(ref Builder b, size_t at) @safe
    {
        const sel = trySel < tries.length && tries[trySel].at == at;
        auto run = at in tryResults;
        if (run is null)
            return sel ? b.add(Widget(kind: WidgetKind.text, slot: Slot.accentPrimary,
                text: "▸ selected: Enter or ▶ runs it")) : uint.max;
        string expected;
        foreach (ref t; tries)
            if (t.at == at)
                expected = t.expected;
        uint[] rows;
        if (!run.ok)
            rows ~= b.add(Widget(kind: WidgetKind.text, slot: Slot.error, text: "✗ " ~ run.error));
        else
        {
            const verdict = expected is null ? "result" : run.trace == expected ? "✓ result, as expected"
                : "✗ result, unlike the expected";
            rows ~= b.add(Widget(kind: WidgetKind.text, text: verdict,
                slot: expected is null || run.trace == expected ? Slot.success : Slot.error));
            import std.algorithm.iteration : splitter;

            foreach (line; run.trace.splitter('\n'))
                if (line.length)
                    rows ~= b.add(Widget(kind: WidgetKind.text, text: line, slot: Slot.code));
            if (run.trace.length == 0)
                rows ~= b.add(Widget(kind: WidgetKind.text, text: "(no members)", slot: Slot.muted));
        }
        return b.add(Widget(kind: WidgetKind.column, children: rows));
    }

    // Scrolls the help so the selected try block shows near the top.
    private void revealTry()
    {
        if (trySel < tries.length)
            if (auto row = tries[trySel].at in tryRows)
                helpTop = max(0, *row - 2);
    }

    // ---- stats -------------------------------------------------------------

    private enum int statsKeyWidth = 13;

    /// The Stats tab's lines, `[key, value]`; an empty key is a heading.
    string[2][] statsLines() const @safe
    {
        string[2][] rows;
        const o = shown;
        if (!o.resolved)
            return [["state", outcome.failed ? outcome.error.message : "no result yet"]];
        size_t files, links, exes;
        foreach (ref m; o.found.members)
        {
            files += m.kind == FsoKind.regular;
            links += m.kind == FsoKind.symlink;
            exes += m.executable;
        }
        rows ~= ["members", text(o.found.members.length)];
        rows ~= ["files", text(files, exes ? text(" (", exes, " executable)") : "")];
        rows ~= ["symlinks", text(links)];
        rows ~= ["size", humanBytes(o.bytes)];
        rows ~= ["dirs walked", text(o.found.directories)];
        rows ~= ["empty dirs", text(o.found.empty.length)];
        rows ~= ["unreadable", text(o.found.unreadable.length)];
        rows ~= ["resolved in", format!"%.2f ms"(o.millis)];
        rows ~= ["", ""];
        if (o.hasIds)
        {
            rows ~= ["castore", o.castore];
            rows ~= ["NarHash", o.narHash];
            rows ~= ["NarSize", humanBytes(o.narSize)];
        }
        else
            rows ~= ["ids", "over " ~ humanBytes(autoIdBytes) ~ ": press i in the tree"];
        rows ~= ["", ""];
        rows ~= ["", "by extension"];
        foreach (e; o.extensions[0 .. min(8, o.extensions.length)])
            rows ~= ["  " ~ e[0], e[1]];
        return rows;
    }

    private uint statsView(ref Builder b, in string[2][] rows)
    {
        uint[] out_;
        foreach (ref kv; rows)
        {
            if (kv[0].length == 0)
            {
                out_ ~= b.add(Widget(kind: WidgetKind.text, text: " " ~ kv[1], slot: Slot.chromeAccent));
                continue;
            }
            Slot s = Slot.code;
            if (kv[0] == "members")
                s = Slot.accentPrimary;
            else if ((kv[0] == "unreadable" || kv[0] == "state") && kv[1] != "0")
                s = Slot.error;
            else if (kv[0] == "empty dirs" && kv[1] != "0")
                s = Slot.warn;
            else if (kv[0] == "ids")
                s = Slot.muted;
            const key = b.add(Widget(kind: WidgetKind.text, text: " " ~ kv[0], slot: Slot.muted,
                width: SizeSpec.fixed(statsKeyWidth)));
            const val = b.add(Widget(kind: WidgetKind.text, text: kv[1], slot: s));
            out_ ~= b.add(Widget(kind: WidgetKind.row, children: [key, val]));
        }
        return b.add(Widget(kind: WidgetKind.column, children: out_, width: SizeSpec.grow()));
    }

    // A bordered pane with a caption; the focused one draws its focus border.
    private uint panel(ref Builder b, string caption, int bodyRows, uint[] body_, bool focused)
    {
        const cap = b.add(Widget(kind: WidgetKind.text, text: caption,
            slot: focused ? Slot.accentPrimary : Slot.muted, textStyle: TextStyle(bold: true)));
        const inner = b.add(Widget(kind: WidgetKind.column, children: body_, width: SizeSpec.grow(),
            height: SizeSpec.fixed(bodyRows)));
        const rows = b.add(Widget(kind: WidgetKind.column, children: [cap, inner], width: SizeSpec.grow()));
        return b.add(Widget(kind: WidgetKind.panel, children: [rows], width: SizeSpec.grow(),
            // The caption sits on the top rule; the body is inside the border.
            padding: Insets(0, 2, 1, 2), decoration: Decoration(
                borderWidth: Insets.all(1),
                borderStyle: BorderStyle.solid,
                borderSlot: focused ? Slot.borderFocus : Slot.border,
            )));
    }

    // ---- events ----------------------------------------------------------

    /// One event.
    void handle(H)(ref H h, in Event e)
    {
        if (isEndOfInput(e))
            return h.quit();
        e.match!(
            (in KeyEvent k) => onKey(h, k),
            (in PasteEvent p) {
                if (focus == Focus.query && query.insert(p.text[], true).changed)
                    refresh();
            },
            (in WheelEvent w) => onWheel(w),
            (in PointerEvent p) => onPointer(p),
            (in _) {},
        );
    }

    // The dock's top edge on screen: the title and the query pane above it.
    private int dockTop() const @safe => dockY;

    private int dockY = 5; // where the last frame put the dock's top row

    private int lastHeight = 30;

    private void onWheel(in WheelEvent w)
    {
        if (!w.dy)
            return;
        // The wheel scrolls the pane under the pointer (`DCK7`).
        const r = paneRect(Pane.help);
        if (helpShown && w.pos.x >= r.x && w.pos.y >= r.y + dockTop)
            helpTop = max(0, helpTop + (w.dy > 0 ? 3 : -3));
        else
            tv.moveSel(w.dy > 0 ? 3 : -3);
    }

    private void onPointer(in PointerEvent p)
    {
        if (p.action != PointerAction.press || p.button != PointerButton.left)
            return;
        // A ▶ the last frame drew runs its block (`FXT2`).
        foreach (ref hit; tryHits)
            if (p.pos.x >= hit.rect.x && p.pos.x < hit.rect.x + hit.rect.width
                && p.pos.y >= hit.rect.y && p.pos.y < hit.rect.y + max(1, hit.rect.height))
                foreach (i, ref t; tries)
                    if (t.at == hit.at)
                        return runTry(i);
        PointerEvent q = p;
        q.pos = Point(p.pos.x, p.pos.y - dockTop);
        const r = dock.handle(cast(const) Event(q));
        if (r.kind != RouteKind.pane)
            return;
        if (r.pane == Pane.tree)
        {
            focus = Focus.tree;
            r.event.match!((in PointerEvent pe) {
                const row = tv.top + pe.pos.y - 1; // under the pane's header
                if (row >= 0 && row < cast(long) tv.rows.length)
                {
                    const wasSel = tv.sel == row;
                    tv.sel = row;
                    if (wasSel && treeActivate(tv, tree, &keyOf) == TreeStep.rebuild)
                        reflatten();
                }
            }, (in _) {});
        }
        else
            focus = Focus.side;
    }

    private void onKey(H)(ref H h, in KeyEvent k)
    {
        lastHeight = h.size.height;
        if (k.key == Key.f1 || (k.key == Key.escape && helpShown && focus == Focus.side))
            return toggleHelp();
        if (k.key == Key.escape && root.inMemory)
        {
            root = dir; // FXT4: back to the directory
            refresh();
            return;
        }
        if (k.key == Key.escape || (k.key == Key.char_ && k.ch == 'c' && k.mods.ctrl))
            return h.quit();
        if (k.key == Key.tab)
        {
            focus = cast(Focus)((focus + (k.mods.shift ? 2 : 1)) % 3);
            return;
        }
        final switch (focus)
        {
            case Focus.query: return queryKey(k);
            case Focus.tree: return treeKey(k);
            case Focus.side: return sideKey(k);
        }
    }

    private void queryKey(in KeyEvent k)
    {
        if (k.key == Key.enter && k.mods.ctrl)
        {
            focus = Focus.tree;
            return;
        }
        // A one-line query leaves Up and Down to the tree: filtering and
        // looking are one motion.
        if (query.state.text.lineCount <= 1
            && (k.key == Key.up || k.key == Key.down || k.key == Key.pageUp || k.key == Key.pageDown))
            return treeKey(k);
        if (query.key(k).changed)
            refresh();
    }

    private void sideKey(in KeyEvent k)
    {
        if (k.key == Key.left || k.key == Key.right)
        {
            dock.activateNext(k.key == Key.right ? 1 : -1);
            return;
        }
        if (!helpShown)
            return;
        const page = max(1, paneRect(Pane.help).height - 2);
        switch (k.key)
        {
            case Key.up: helpTop = max(0, helpTop - 1); break;
            case Key.down: helpTop += 1; break;
            case Key.pageUp: helpTop = max(0, helpTop - page); break;
            case Key.pageDown: helpTop += page; break;
            case Key.home: helpTop = 0; break;
            case Key.enter: runTry(trySel); break;
            case Key.char_:
                if (tries.length && (k.ch == 'n' || k.ch == 'p'))
                {
                    trySel = k.ch == 'n' ? (trySel + 1) % tries.length
                        : (trySel + tries.length - 1) % tries.length;
                    revealTry();
                }
                break;
            default: break;
        }
    }

    private void treeKey(in KeyEvent k)
    {
        const page = tv.bodyRows > 1 ? tv.bodyRows - 1 : 1;
        switch (k.key)
        {
            case Key.up: tv.moveSel(-1); break;
            case Key.down: tv.moveSel(1); break;
            case Key.pageUp: tv.moveSel(-page); break;
            case Key.pageDown: tv.moveSel(page); break;
            case Key.home: tv.selHome(); break;
            case Key.end: tv.selEnd(); break;
            case Key.left:
                if (collapseOrUp(tv, tree, &keyOf) == TreeStep.rebuild)
                    reflatten();
                break;
            case Key.right:
                const n = tv.selectedNode;
                if (n != uint.max && tree.nodes[n].value.isDir && !tv.open.isOpen(keyOf(n)))
                {
                    tv.open = tv.open.opened(keyOf(n));
                    reflatten();
                }
                break;
            case Key.enter:
                if (treeActivate(tv, tree, &keyOf) == TreeStep.rebuild)
                    reflatten();
                break;
            case Key.char_:
                switch (k.ch)
                {
                    case 'j': tv.moveSel(1); break;
                    case 'k': tv.moveSel(-1); break;
                    case 'o':
                        tv.open = typeof(tv.open).allOpen;
                        reflatten();
                        break;
                    case 'c':
                        tv.open = typeof(tv.open).allClosed;
                        reflatten();
                        break;
                    case 'i':
                        idsRequested = true;
                        refresh();
                        break;
                    default: break;
                }
                break;
            default: break;
        }
    }
}

/// Where a frame drew a try block's ▶, and the block's identity.
struct TryHit
{
    Rect rect; ///
    size_t at; ///
}

/// The slot each token kind is drawn in (`FXU4`).
Slot slotOf(TokenKind k) @safe pure nothrow @nogc
{
    final switch (k)
    {
        case TokenKind.glob: return Slot.code;
        case TokenKind.string_: return Slot.success;
        case TokenKind.keyword: return Slot.accentPrimary;
        case TokenKind.operator: return Slot.warn;
        case TokenKind.function_: return Slot.info;
        case TokenKind.predicate: return Slot.accentSecondary;
        case TokenKind.comment: return Slot.muted;
        case TokenKind.punctuation: return Slot.textSecondary;
    }
}

/**
`spans`, cut at token boundaries and drawn in each token's slot, with the
bytes of `error` in the error slot (`FXU4`). Selected spans keep their slot.
*/
TextSpan[] highlight(TextSpan[] spans, in Token[] tokens, Span error) @safe pure nothrow
{
    TextSpan[] out_;
    foreach (s; spans)
    {
        if (s.slot == Slot.selection || s.srcEnd <= s.srcStart)
        {
            out_ ~= s;
            continue;
        }
        size_t at = s.srcStart;
        while (at < s.srcEnd)
        {
            // The token holding `at`, or the gap up to the next one.
            size_t end = s.srcEnd;
            Slot slot = s.slot;
            foreach (ref t; tokens)
            {
                if (t.span.end <= at)
                    continue;
                if (t.span.start > at)
                {
                    end = min(end, t.span.start);
                    break;
                }
                end = min(end, t.span.end);
                slot = slotOf(t.kind);
                break;
            }
            if (error.start < error.end)
            {
                if (at >= error.start && at < error.end)
                {
                    slot = Slot.error;
                    end = min(end, error.end);
                }
                else if (error.start > at)
                    end = min(end, error.start);
            }
            TextSpan piece = s;
            piece.text = s.text[at - s.srcStart .. end - s.srcStart];
            piece.srcStart = at;
            piece.srcEnd = end;
            piece.slot = slot;
            out_ ~= piece;
            at = end;
        }
    }
    return out_;
}

/// FXU4: each token is drawn in its kind's slot, and an error's bytes in the
/// error slot, without moving a character.
@("fileset_explorer.highlight")
@safe unittest
{
    import sparkles.build_primitives.fileset.query : parseQuery;
    import sparkles.ui.editor.state : EditorState;

    const src = "a | \"b\" # c";
    const q = parseQuery(src);
    EditorViewOptions o;
    o.hostCursor = true;
    auto spans = highlight(editorLineSpans(EditorState.create(src), 0, o), q.tokens,
        Span(size_t.max, size_t.max));
    string joined;
    Slot[] slots;
    foreach (s; spans)
    {
        joined ~= s.text;
        slots ~= s.slot;
    }
    assert(joined == src);
    assert(slots == [Slot.code, Slot.inherit, Slot.warn, Slot.inherit, Slot.success, Slot.inherit,
        Slot.muted], text(slots));

    auto marked = highlight(editorLineSpans(EditorState.create(src), 0, o), q.tokens, Span(4, 7));
    foreach (s; marked)
        if (s.text == "\"b\"")
            assert(s.slot == Slot.error);
}
