/**
The fileset explorer as a `runApp` component (`FXU1`–`FXU9`).

The screen is a title line, the query editor, a dock and a key hint line.
The dock holds the member tree on the left and, on the right, one tabbed
group: Stats, Help and Export. Every edit of the query re-parses and
re-resolves it and redraws everything from the new result (`FXU1`).
*/
module explorer;

import core.time : MonoTime;
import std.algorithm.comparison : max, min;
import std.conv : text;
import std.format : format;
import std.math : abs, floor;

import sparkles.base.text.grapheme : visibleWidth;
import sparkles.build_primitives.fileset.fso : FsoKind;
import sparkles.build_primitives.fileset.query : Span, Token, TokenKind;
import sparkles.input : Event, isDismiss, isEndOfInput, Key, KeyEvent, match, Mods, PasteEvent, Point,
    PointerAction, PointerButton, PointerEvent, WheelEvent;
import sparkles.base.term_control : PointerShape;
import sparkles.ui.components.chrome : scrollbar, ScrollbarSpec, tabStrip;
import sparkles.ui.hit_ids : HitBlock;
import sparkles.ui.editor.command : EditCommand;
import sparkles.ui.state : ScrollAxis, scrollbarThumb, sourceOffsetAt;
import sparkles.ui.components.controls : chip, ControlSize, segmented;
import sparkles.ui.components.dock : DockAxis, DockContainer, DockKind, DockLayout, PaneId;
import sparkles.ui.components.editor : caretColumnOf, editorLineSpans, EditorViewOptions;
import sparkles.ui.components.tree_view : collapseOrUp, measureContent, TreeStep, TreeViewState,
    treeActivate = activate, viewSlice;
import sparkles.ui.components.scroll_body : ScrollBody;
import sparkles.ui.components.tree_widget : flatten, Guide, TreeData, TreeGlyphs, treeRows = treeView;
import sparkles.ui.editor.field : EditorField;
import sparkles.ui.geometry : Insets, Rect, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, FontRole, Slot, TextStyle, TypeStep;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;

import evaluate : autoIdBytes, evaluate, humanBytes, Outcome, Root;
import send : SendStage, Sending, shareText;
import stats : nameKeys, nameValueOf, statsKeyWidth, statsRows;
import help : helpSource, namedTrees, runFileset, TryBlock, tryBlocks, TryOutcome;
import export_tab : exportFor, highlightCode, languageOf, targets;
import sparkles.build_primitives.fileset.emit : Emitted, NixGlobs, Target, targetName;
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
    size_t trySel;                  /// the selected try block
    TryOutcome[size_t] tryResults;  /// by the block's `at`
    /// The cheat sheet's snippets, each a query a ▶ tries (`FXU19`).
    Cheat[] cheats;
    private Point cheatAt;          // a press on the help, for `paint` to resolve
    private bool cheatPending;
    private size_t lastTab;         // the tab F1 returns to
    private Focus lastFocus;        // and the focus
    private TryHit[] tryHits;       // where this frame drew each ▶ (`paint`)
    // The help's fences scrolled across (`FXU25`): each one's offset in
    // cells by its body's start, and where this frame drew each viewport.
    private double[size_t] fenceX;
    private FenceView[] fenceViews;
    // The scroll gesture under way: whether its axis is chosen, whether it
    // is across, and the fence it moves (`size_t.max`: none).
    private bool gestureAxisSet, gestureAcross;
    private size_t gestureFence = size_t.max;
    private int[size_t] tryRows;    // each try block's row in the help's content

    /// The help's row of the try block at `at`, as last drawn; -1 when not drawn.
    int tryRowOf(size_t at) const @safe
    {
        if (auto r = at in tryRows)
            return *r;
        return -1;
    }

    // Scrolling (`FXU10`): each pane's position, in rows, moved 1:1 by a
    // finger, flung on by a lifted one, eased by a wheel notch or a key.
    ScrollBody treeScroll;          /// the member tree's
    ScrollBody helpScroll;          /// the help's
    ScrollBody exportScroll;        /// the Export tab's
    ScrollBody exportScrollX;       /// ... across, in columns, for its long lines
    /// Ease between positions on a target that can show a fraction of a row;
    /// off, every move lands at once (`--render-plain`, a terminal).
    bool smoothScroll = true;
    private long syncedTop;         // `tv.top` as the tree's motion last left it
    private MonoTime lastFrame;     // when the previous frame was built
    private uint helpContent = uint.max; // the help's content node, measured in `paint`
    private TryHit[] buttons;       // tabs and Export buttons, as this frame drew them
    private bool keyboardWanted;    // the query was tapped: on a phone, the soft keyboard
    private bool keyboardShown;     // what the host was last told

    /// The first row of the help that shows.
    int helpTop() const @safe => cast(int) helpScroll.motion.whole;

    /// The base of the ▶ hit ids: `tryHitBase + at`.
    enum size_t tryHitBase = 1 << 24;
    /// The right group's tabs: `tabHitBase + i`.
    enum size_t tabHitBase = 1 << 22;
    /// The overlay bars (`FXU14`): `barHitBase + Bar`.
    enum size_t barHitBase = tabHitBase + 8;
    /// The query editor's lines (`FXU15`).
    enum size_t queryHit = tabHitBase + 12;
    /// The Export tab's buttons: previous and next target, glob mode, copy.
    enum size_t exportHitBase = tabHitBase + 16;

    /// The panes that scroll, each with its bar (`FXU14`).
    enum Bar : ubyte
    {
        tree,    ///
        help,    ///
        export_, ///
    }

    private enum noBar = -1;
    private Rect[Bar.max + 1] barRects; // where this frame drew each bar; empty: none
    private int barHot = noBar;         // the bar under the pointer
    private int barGrab = noBar;        // the bar a pointer holds
    private int grabAt;                 // and where in its thumb, in cells
    private Rect queryRect;             // the query's lines, as this frame drew them
    private PointerShape shape = PointerShape.default_; // what the host was last asked for

    /// Where the last frame drew bar `which`; empty when it drew none.
    Rect barRect(Bar which) const @safe => barRects[which];
    /// Where the last frame drew the query's lines.
    Rect queryArea() const @safe => queryRect;

    /// Starts on `source` beneath `dir`.
    this(Root dir, string source)
    {
        this.dir = dir;
        this.root = dir;
        query = EditorField.make(source);
        tv.open = typeof(tv.open).allOpen;
        tv.chromeRows = 0;
        tv.headerRows = 0;
        dock.layout = initialLayout(tabsNode, helpLeaf, exportLeaf);
        dock.focused = Pane.tree;
        loadHelp();
        refresh();
    }

    // Parses the help page; without the markdown grammar it stays its text.
    private void loadHelp() @system
    {
        import sparkles.syntax.md.model : extractMarkdown;
        import launch : appGrammars;

        auto registry = appGrammars();
        helpDoc = extractMarkdown(registry, helpSource);
        tries = tryBlocks(helpDoc);
        trees = namedTrees(helpDoc);
        cheats = cheatSnippets(helpDoc, helpSource);
    }

    /// Tries cheat sheet snippet `i` (`FXU19`): its query goes into the
    /// editor, resolved against the directory; the help stays.
    void tryCheat(size_t i)
    {
        if (i >= cheats.length)
            return;
        query = EditorField.make(cheats[i].query);
        root = dir;
        refresh();
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

    private uint helpLeaf, exportLeaf;
    // The help's fences, highlighted: by language and body.
    private TextSpan[][][string] fenceLines;

    // The Export tab (`FXE12`): the target, Nix's glob mode, and the code for
    // the last query, recomputed when the tab shows a stale one.
    Target exportTarget = Target.nix; ///
    NixGlobs nixGlobs;                ///
    Emitted exported;                 ///
    private bool exportStale = true;
    // Export's controls are on the tabs' row this frame (`FXU23`).
    private bool exportControlsInStrip;

    /// Whether the Export tab is the one showing.
    bool exportShown() const @safe
        => dock.layout.nodes[tabsNode].children[dock.layout.nodes[tabsNode].active] == exportLeaf;

    /// The code for the current query, brought up to date.
    ref const(Emitted) currentExport()
    {
        if (exportStale)
        {
            exported = outcome.query.ok && outcome.resolved
                ? exportFor(exportTarget, nixGlobs, root, outcome.query, outcome)
                : Emitted(false, null, outcome.query.ok ? outcome.error.message : "the query does not parse");
            exportStale = false;
            // Highlighted once per export, not once a frame (`FXU20`).
            exportLines = exported.ok ? highlightCode(languageOf(exportTarget), exported.code) : null;
            exportWidth = 0;
            foreach (line; exportLines)
            {
                long w;
                foreach (ref s; line)
                    w += visibleWidth(s.text);
                exportWidth = max(exportWidth, w);
            }
        }
        return exported;
    }

    /// The export's lines, highlighted, as `currentExport` last made them.
    TextSpan[][] exportLines;
    /// The widest of them, in cells: how far the Export tab scrolls across.
    long exportWidth;

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
    /// So do the tabs and the Export tab's buttons (`FXU10`), and the help's
    /// height, which bounds its scrolling.
    void paint(H)(ref H h, in WidgetTree t, in Frame[] frames)
    {
        import sparkles.source_view.markdown : fenceShiftKeyBase, shiftKeyMask;

        tryHits.length = 0;
        buttons.length = 0;
        fenceViews.length = 0;
        Rect[] frameBoxes;
        barRects[] = Rect.init;
        queryRect = Rect.init;
        foreach (i, ref n; t.nodes)
        {
            if (i >= frames.length)
                break;
            // A fence body's viewport (not its number gutter): its lines'
            // widest is how far it scrolls across.
            if ((n.key & shiftKeyMask) == fenceShiftKeyBase && n.clipX)
            {
                int widest;
                foreach (c; n.children)
                    if (c < frames.length)
                        widest = max(widest, frames[c].rect.width);
                fenceViews ~= FenceView(frames[i].rect, n.key & ~shiftKeyMask, widest, frames[i].rect);
            }
            if (n.decoration.insideGlyphFrame)
                frameBoxes ~= frames[i].rect;
            if (n.hitId >= tryHitBase && n.hitId < tryHitBase + helpSource.length)
                tryHits ~= TryHit(frames[i].rect, n.hitId - tryHitBase);
            else if (n.hitId >= barHitBase && n.hitId <= barHitBase + Bar.max)
                barRects[n.hitId - barHitBase] = frames[i].rect;
            else if (n.hitId == queryHit)
                queryRect = frames[i].rect;
            else if ((n.hitId >= tabHitBase && n.hitId < actionBase + Action.insert + chipTexts.length)
                    || (n.hitId >= statsHitBase && n.hitId <= sendHitBase + SendButton.max))
                buttons ~= TryHit(frames[i].rect, n.hitId);
        }
        // A fence's box: the smallest glyph frame around its viewport, the
        // badges' row and the bottom rule included.
        foreach (ref f; fenceViews)
            foreach (box; frameBoxes)
                if (box.x <= f.rect.x && box.y <= f.rect.y && box.x + box.width >= f.rect.x + f.rect.width
                    && box.y + box.height >= f.rect.y + f.rect.height
                    && (f.box == f.rect || box.width * box.height < f.box.width * f.box.height))
                    f.box = box;
        const r = paneRect(Pane.help);
        foreach (ref hit; tryHits)
            tryRows[hit.at] = hit.rect.y - (r.y + dockTop) + helpTop;
        if (helpContent < frames.length)
            helpScroll.content = frames[helpContent].rect.height;
        // A press on the help: a cheat sheet snippet, or its ▶, tries it (`FXU19`).
        if (cheatPending)
        {
            cheatPending = false;
            const at = sourceOffsetAt(t, frames, cheatAt);
            foreach (i, ref c; cheats)
                if (at >= 0 && at >= c.start && at <= c.end)
                {
                    tryCheat(i);
                    h.requestFrame();
                    break;
                }
        }
    }

    /// Re-evaluates the query and rebuilds the tree, keeping what was open.
    void refresh()
    {
        outcome = evaluate(root, query.text, idsRequested);
        exportStale = true;
        copiedName = size_t.max; // a copied mark belongs to the names it copied
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
        // A send runs on its own threads: read where it is before drawing it.
        sending.tick();

        // The touch layout (`FXU11`), on a screen without hover unless chosen.
        bool hostTouch;
        static if (__traits(hasMember, H, "capabilities"))
            hostTouch = !h.capabilities.hover;
        touch = layout == Layout.touch || (layout == Layout.automatic && hostTouch);
        measureCell(h);
        rowCells = touch ? cellsFor(48, cellDp) : 1;
        treeRowCells = touch ? cellsFor(32, cellDp) : 1;
        treeScroll.touch = helpScroll.touch = exportScroll.touch = exportScrollX.touch = touch;

        // The query: its lines up to a third of the screen, and the status.
        const lines = query.state.text.lineCount;
        const room = max(1, size.height / 3 - 3);
        const queryRows = cast(int) min(lines, room);
        uint[] top;
        int topRows;
        if (touch)
        {
            top = [appBar(b), queryField(b, queryRows), operatorChips(b, size.width)];
            topRows = rowCells + (queryRows + 2) + 1 + rowCells;
        }
        else
        {
            top = [b.add(Widget(kind: WidgetKind.rich, width: SizeSpec.grow(), spans: [
                    TextSpan(" fileset explorer ", Slot.chromeAccent, TextStyle(bold: true)),
                    TextSpan(root.inMemory ? "tutorial tree `" ~ root.name ~ "` (Esc returns)" : dir.dir,
                        root.inMemory ? Slot.warn : Slot.muted),
                ])),
                panel(b, "query", queryRows + 1, queryLines(b, queryRows) ~ statusLine(b),
                    focus == Focus.query)];
            topRows = 1 + queryRows + 3;
        }

        // The dock fills the rest, above the key hints on a keyboard's layout.
        const footerRows = touch ? 0 : 1;
        const dockRows = max(4, size.height - topRows - footerRows);
        dockY = topRows;
        const stats = statsLines();
        arrangeDock(size.width, dockRows, stats);
        // The time since the last frame: the host's measure where it has
        // one (a recorded run's is fixed), else the clock's.
        const now = MonoTime.currTime;
        double dt = lastFrame == MonoTime.init ? 0 : (now - lastFrame).total!"usecs" / 1e6;
        lastFrame = now;
        static if (__traits(hasMember, H, "frameSeconds"))
            if (h.frameSeconds > 0)
                dt = h.frameSeconds;
        if (animate(min(dt, 0.1), smoothScroll && h.target.subCellScroll && !h.target.reducedMotion))
            h.requestFrame();
        // A running send is read again with no input arriving (`FXS4`).
        if (sending.running)
        {
            import core.time : msecs;

            static if (__traits(compiles, h.wakeIn(250.msecs)))
                h.wakeIn(250.msecs);
        }
        static if (__traits(compiles, h.textInput(true)))
        {
            // A phone's soft keyboard, while the query has a tapped focus.
            const wanted = keyboardWanted && focus == Focus.query;
            if (wanted != keyboardShown)
            {
                h.textInput(wanted);
                keyboardShown = wanted;
            }
        }
        const dockView = b.add(Widget(kind: WidgetKind.column, width: SizeSpec.grow(),
            height: SizeSpec.fixed(dockRows), children: [renderNode(b, dock.layout.root, stats)]));

        uint[] all = top ~ dockView;
        if (!touch)
            all ~= b.add(Widget(kind: WidgetKind.text, slot: Slot.muted, text: hints()));
        return b.finish(b.add(Widget(kind: WidgetKind.column, width: SizeSpec.grow(), children: all)));
    }

    /// Which layout to draw (`FXU11`).
    enum Layout : ubyte
    {
        automatic, /// the touch layout on a screen without hover
        keyboard,  /// the bordered, key-hinted layout
        touch,     /// the touch layout
    }

    /// ditto
    Layout layout;
    /// Whether this frame drew the touch layout.
    bool touch;
    /// The height of a touch target, in cells: a chip, a segment (`TOK11`).
    int rowCells = 1;
    /// The height of a tree row, in cells: a dense list, 32 dp on the touch
    /// layout (`FXU11`).
    int treeRowCells = 1;

    /// A cell's height in dp, as the host last reported it (24 when it does not).
    double cellDp = 24;

    /// The whole cells `dp` takes at `cellDp` a cell, at least one.
    static int cellsFor(double dp, double cellDp) @safe pure nothrow @nogc
    {
        import std.math : ceil;

        return cellDp > 0 ? max(1, cast(int) ceil(dp / cellDp)) : 1;
    }

    // The cell's height in dp, from the host's cell height and density where
    // it reports them.
    private void measureCell(H)(ref H h)
    {
        static if (__traits(hasMember, H, "cellHeight") && __traits(hasMember, H, "fontDensity"))
        {
            const cell = h.cellHeight, density = h.fontDensity;
            if (cell > 0 && density > 0)
                cellDp = cell / density;
        }
    }

    // ---- the touch layout's chrome (`FXU11`) --------------------------------

    /*
    `child`, a cell tall, in the middle of a touch target `rowCells` tall
    (`TOK11`). Layout places it in whole cells; the half cell an even target
    leaves is taken up by a fractional offset, so a label sits where a pill
    drawn at its target's middle is. `hitId`, when given, makes the whole
    target the hit area, not just the cell drawn. A crowded row on a phone
    never squeezes it, unless it is `shrinkable`.
    */
    private uint centred(ref Builder b, uint child, size_t hitId = 0, bool shrinkable = false)
    {
        auto w = Widget(kind: WidgetKind.column, children: [child], height: SizeSpec.fixed(rowCells),
            alignY: Alignment.center, clipY: true, clipX: shrinkable, hitId: hitId,
            width: shrinkable ? SizeSpec.fit_ : SizeSpec.rigid_);
        if ((rowCells - 1) % 2)
            w.childOffsetFracY = -0.5f;
        return b.add(w);
    }

    /*
    A pill over the whole touch target (`FXU17`): its box is the target, so
    the 32 dp it is drawn at is centred in the target's height with room
    above and below its label — a box a cell tall would be drawn a cell tall,
    hugging the label. The label is centred in the target as `centred` does.
    Rigid: a crowded row never squeezes it.
    */
    private uint pill(ref Builder b, uint box)
    {
        auto w = &b.nodes[box];
        w.height = SizeSpec.fixed(rowCells);
        w.width = SizeSpec.rigid_;
        w.alignY = Alignment.center;
        w.clipY = true;
        if ((rowCells - 1) % 2)
            w.childOffsetFracY = -0.5f;
        return box;
    }

    // A chip drawn compact, centred in its touch target.
    private uint touchChip(ref Builder b, string label, size_t hitId)
        => pill(b, chip(b, label, hitId, false, ControlSize(rows: rowCells)));

    // A segmented control of touch targets: segment `i`'s hit id is `firstHit + i`.
    private uint touchSegments(ref Builder b, in string[] labels, size_t selected, size_t firstHit)
    {
        uint[] segs;
        foreach (i, l; labels)
        {
            const on = i == selected;
            const t = b.add(Widget(kind: WidgetKind.text, text: l, alignX: Alignment.center,
                slot: on ? Slot.chromeAccent : Slot.textPrimary, textStyle: TextStyle(bold: on)));
            // Inset within the group's 32 dp outline by 3 dp on every side, as a
            // segment is: the outline's sides as far off as its top and bottom.
            segs ~= pill(b, b.add(Widget(kind: WidgetKind.panel, children: [t], padding: Insets(0, 1, 0, 1),
                hitId: firstHit + i, slot: on ? Slot.chromeAccent : Slot.surfaceRaised, paintBackground: on,
                decoration: Decoration(borderRadius: 3, drawHeight: 32, drawInset: 3))));
        }
        // The group's outline is drawn at the target's middle, around the segments.
        return b.add(Widget(kind: WidgetKind.row, children: segs, height: SizeSpec.fixed(rowCells),
            decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets.all(1),
                borderSlot: Slot.border, borderRadius: 6, drawHeight: 32)));
    }

    // The cells `touchSegments` takes for `labels`: each label and a cell either side.
    private static int segmentsWidth(in string[] labels) @safe
    {
        int w;
        foreach (l; labels)
            w += cast(int) visibleWidth(l) + 2;
        return w;
    }

    private static immutable string[] nixModes = ["glob shim", "expand", "refuse"];
    // ditto, where a half's tabs row is short of a few cells for them.
    private static immutable string[] nixModesShort = ["shim", "expand", "refuse"];
    // The glob modes' segments are drawn with the short labels this frame.
    private bool shortModes;

    // Export's target between round buttons: ◀, its name, ▶.
    private uint[] exportTargetControls(ref Builder b)
    {
        const name = centred(b, b.add(Widget(kind: WidgetKind.text, text: targetName(exportTarget),
            slot: Slot.accentPrimary, textStyle: TextStyle(bold: true))));
        return [touchChip(b, "◀", exportHitBase + 0), gapCells(b, 1), name, gapCells(b, 1),
            touchChip(b, "▶", exportHitBase + 1)];
    }

    // Nix's glob mode, as segments.
    private uint nixModeSegments(ref Builder b)
        => touchSegments(b, shortModes ? nixModesShort : nixModes, nixGlobs, actionBase + Action.globShim);

    private static uint gapCells(ref Builder b, int n)
        => b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(n)));

    /*
    Export's controls on the tabs' row (`FXU23`): the target, Nix's glob mode
    when it is Nix, and copying when there is something to copy, as wide as
    `exportControlsWidth` says.
    */
    private uint[] exportControls(ref Builder b)
    {
        uint[] parts = exportTargetControls(b);
        if (exportTarget == Target.nix)
            parts ~= [gapCells(b, 1), nixModeSegments(b)];
        parts ~= b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
        if (currentExport.ok)
            parts ~= touchChip(b, "Copy", exportHitBase + 3);
        return parts;
    }

    // ditto: the cells it needs, chips and segments a cell wider each side
    // than their labels, with the glob modes' short labels or not.
    private int exportControlsWidth(bool short_)
    {
        int w = 3 + 1 + cast(int) visibleWidth(targetName(exportTarget)) + 1 + 3;
        if (exportTarget == Target.nix)
            w += 1 + segmentsWidth(short_ ? nixModesShort : nixModes);
        if (currentExport.ok)
            w += 1 + 6;
        return w;
    }

    /// What the touch layout's buttons do: their hit ids are `actionBase + Action`.
    enum Action : size_t
    {
        expandAll,
        collapseAll,
        computeIds,
        globShim,
        globExpand,
        globRefuse,
        clear,
        backspace,
        insert, /// `insert + i`: `operatorChips`' `i`th chip
    }

    /// The base of the touch layout's buttons.
    enum size_t actionBase = tabHitBase + 32;

    // The chips under the query: label, and what it inserts (`""`: an action).
    private static immutable string[2][] chipTexts = [
        ["|", " | "], ["&", " & "], ["−", " - "], ["( )", "()"], ["**", "**/"], ["*", "*"],
        ["\" \"", "\"\""], ["#", "  # "],
    ];

    private uint appBar(ref Builder b)
    {
        const title = centred(b, b.add(Widget(kind: WidgetKind.text, text: "Fileset explorer", slot: Slot.textPrimary,
            textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.title, bold: true))));
        import std.path : absolutePath, baseName, buildNormalizedPath;

        const where = centred(b, b.add(Widget(kind: WidgetKind.text,
            text: root.inMemory ? "tutorial tree " ~ root.name ~ " · Back returns"
                : baseName(buildNormalizedPath(absolutePath(dir.dir))),
            slot: root.inMemory ? Slot.warn : Slot.textSecondary,
            textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.caption))), shrinkable: true);
        const gap = b.add(Widget(kind: WidgetKind.box, width: SizeSpec(SizeSpec.Kind.fixed, 2, rigid: true)));
        const count = centred(b, b.add(Widget(kind: WidgetKind.text,
            text: text(shown.found.members.length, shown.found.members.length == 1 ? " member" : " members"),
            slot: Slot.accentPrimary, textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.label))));
        const fill = b.add(Widget(kind: WidgetKind.box, width: SizeSpec(SizeSpec.Kind.grow, 1, min: 2, rigid: true)));
        return b.add(Widget(kind: WidgetKind.row, width: SizeSpec.grow(), padding: Insets(0, 2, 0, 2),
            children: [title, gap, where, fill, count]));
    }

    // The query as a filled, rounded field, its canonical form or error under it.
    private uint queryField(ref Builder b, int queryRows)
    {
        // A row of space above and below the lines, which stay on whole cells
        // for the host's cursor; the fill is drawn around the lines with some
        // of that space, centred, not across all of it.
        const rows = queryRows + 2;
        const lines = b.add(Widget(kind: WidgetKind.column, children: queryLines(b, queryRows),
            width: SizeSpec.grow(), alignY: Alignment.center, height: SizeSpec.fixed(rows)));
        const field = b.add(Widget(kind: WidgetKind.column, children: [lines], width: SizeSpec.grow(),
            // Focus raises the fill rather than drawing a border, which a cell
            // target would take whole rows for.
            height: SizeSpec.fixed(rows), padding: Insets(0, 2, 0, 2),
            slot: focus == Focus.query ? Slot.surfaceRaised : Slot.surfaceSunken,
            paintBackground: true, decoration: Decoration(borderRadius: 16,
                drawHeight: cast(int)(queryRows * cellDp + 24))));
        return b.add(Widget(kind: WidgetKind.column, width: SizeSpec.grow(), padding: Insets(0, 2, 0, 2),
            children: [field, statusLine(b)]));
    }

    // The operator chips, then clear and backspace. A screen too narrow for
    // the row with a cell between chips sets them side by side: the pills
    // are drawn inside their cells, so they still stand apart.
    private uint operatorChips(ref Builder b, int width)
    {
        // Each chip is its label and a cell each side; then ⌫, Clear and the padding.
        int need = 2 + 1 + 3 + 1 + 7 + 4;
        foreach (c; chipTexts)
            need += cast(int) visibleWidth(c[0]) + 2 + 1;
        const between = need <= width ? 1 : 0;
        uint[] chips;
        foreach (i, c; chipTexts)
        {
            chips ~= touchChip(b, c[0], actionBase + Action.insert + i);
            chips ~= b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(between)));
        }
        chips ~= b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
        chips ~= touchChip(b, "⌫", actionBase + Action.backspace);
        chips ~= b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(1)));
        chips ~= touchChip(b, "Clear", actionBase + Action.clear);
        return b.add(Widget(kind: WidgetKind.row, children: chips, width: SizeSpec.grow(),
            height: SizeSpec.fixed(rowCells), padding: Insets(0, 2, 0, 2)));
    }

    /**
    Steps each pane's motion `dt` seconds, and keeps the tree's view where
    its cursor puts it: a key that moves the cursor out of view scrolls to it
    (eased, when `smooth`), and a scroll leaves the cursor where it is. True
    while a motion needs the next frame.
    */
    private bool animate(double dt, bool smooth)
    {
        treeScroll.motion.instant = helpScroll.motion.instant = exportScroll.motion.instant
            = exportScrollX.motion.instant = !smooth;

        treeScroll.content = tv.rows.length;
        treeScroll.viewport = tv.bodyRows;
        helpScroll.viewport = paneRect(Pane.help).height;
        if (tv.top != syncedTop)
            treeScroll.motion.scrollTo(tv.top, treeScroll.limit);
        bool moving = treeScroll.animate(cast(float) dt);
        moving |= helpScroll.animate(cast(float) dt);
        moving |= exportScroll.animate(cast(float) dt);
        moving |= exportScrollX.animate(cast(float) dt);
        tv.top = treeScroll.motion.whole;
        syncedTop = tv.top;
        return moving;
    }

    // The scroll body of the pane under `p` (screen cells), if it scrolls.
    private ScrollBody* scrollAt(Point p) return @safe
    {
        bool under(Pane pane)
        {
            const r = paneRect(pane);
            const y = p.y - dockTop;
            return p.x >= r.x && p.x < r.x + r.width && y >= r.y - 1 && y < r.y + r.height;
        }
        if (under(Pane.tree))
            return &treeScroll;
        if (helpShown && under(Pane.help))
            return &helpScroll;
        if (exportShown && under(Pane.export_))
            return &exportScroll;
        return null;
    }

    private string hints() const @safe
    {
        final switch (focus)
        {
            case Focus.query:
                return " type to query live · | & - ( ) # · Tab tree · F1 help · Esc quit";
            case Focus.tree:
                return " ↑↓ move · ←→ close/open · ⏎ toggle · o/c all · i ids · Tab side · F1 help · Esc quit";
            case Focus.side:
                return statsShown ? " ←→ tabs · ↑↓ choose · y copy · s send · Tab query · F1 help · Esc quit"
                    : " ←→ tabs · ↑↓ scroll · Tab query · F1 help · Esc quit";
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
        // The error's bytes, or, with the Export tab showing, what the target refused (`FXE12`).
        Span marked = outcome.failed ? errorSpan() : Span(size_t.max, size_t.max);
        if (!outcome.failed && exportShown && !currentExport.ok && currentExport.span.end > currentExport.span.start)
            marked = Span(currentExport.span.start, currentExport.span.end);
        foreach (line; first .. min(lineCount, first + rows))
        {
            auto spans = highlight(editorLineSpans(query.state, line, o), outcome.query.tokens, marked);
            const prompt = b.add(Widget(kind: WidgetKind.text, text: line == 0 ? "❯ " : "  ", width: SizeSpec.rigid_,
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
        // One column, for a pointer to find (`FXU15`).
        return [b.add(Widget(kind: WidgetKind.column, children: out_, width: SizeSpec.grow(),
            hitId: queryHit))];
    }

    /// The byte of the query a click on screen cell `p` puts the caret at
    /// (`FXU15`): before the character under it, or at its line's end.
    size_t queryOffsetAt(Point p) const @safe
    {
        import std.utf : decode;

        const src = query.text;
        // The line clicked: the editor's first shown one, plus the row.
        size_t line = firstLine + max(0, p.y - queryRect.y), at;
        foreach (_; 0 .. line)
        {
            while (at < src.length && src[at] != '\n')
                ++at;
            if (at == src.length)
                return at;
            ++at;
        }
        // The column past the two-cell prompt, character by character.
        const col = p.x - queryRect.x - 2;
        int x;
        while (at < src.length && src[at] != '\n')
        {
            size_t next = at;
            cast(void) decode(src, next);
            const w = cast(int) visibleWidth(src[at .. next]);
            if (x + w > col)
                break;
            x += w;
            at = next;
        }
        return at;
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
        TextSpan[] spans = [TextSpan("  = ", Slot.muted), TextSpan(canonical(outcome.query), Slot.code)];
        // A bare call name that names no file (`FXL9`).
        foreach (h; outcome.hints)
            spans ~= [TextSpan("   ", Slot.muted), TextSpan(h, Slot.warn)];
        return b.add(Widget(kind: WidgetKind.rich, width: SizeSpec.grow(), spans: spans));
    }

    // ---- the dock --------------------------------------------------------

    private static DockLayout initialLayout(out uint tabs, out uint helpLeaf, out uint exportLeaf)
    {
        DockLayout l;
        const t = l.addLeaf(Pane.tree, minExtent: 20);
        l.nodes[t].title = "members";
        l.nodes[t].headerExtent = 1;
        const s = l.addLeaf(Pane.stats);
        l.nodes[s].title = "Stats";
        helpLeaf = l.addLeaf(Pane.help);
        l.nodes[helpLeaf].title = "Help";
        exportLeaf = l.addLeaf(Pane.export_);
        l.nodes[exportLeaf].title = "Export";
        tabs = l.addTabs([s, helpLeaf, exportLeaf]);
        l.root = l.addSplit(DockAxis.horizontal, [t, tabs]);
        return l;
    }

    /// Halves the width between the tree and the right group (`FXU5`), or
    /// stacks them on a narrow touch screen (`FXU12`), and arranges the dock.
    private void arrangeDock(int width, int rows, in string[2][] stats)
    {
        auto l = &dock.layout;
        // Touch: a segmented control and the tree's header are touch targets;
        // a screen narrower than two 48-column panes stacks them (`FXU12`).
        l.tabStripExtent = rowCells;
        l.nodes[l.nodes[l.root].children[0]].headerExtent = rowCells;
        const stacked = touch && width < 2 * 48;
        l.nodes[l.root].axis = stacked ? DockAxis.vertical : DockAxis.horizontal;
        if (stacked)
            l.nodes[tabsNode].extent = max(rowCells + 4, rows / 2);
        else // side by side, the two halves alike whatever the tab (`FXU5`)
            l.nodes[tabsNode].extent = max(1, (width - 1) / 2);
        dock.arrange(Rect(0, 0, width, rows));
        // In tree rows: `tv` counts rows, each `treeRowCells` tall.
        foreach (ref f; dock.frames.panes)
            if (f.pane == Pane.tree)
            {
                tv.width = f.rect.width;
                tv.resize(max(1, f.rect.height / treeRowCells));
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
            // Tapped or clicked, a tab shows its pane (`FXU10`); on the touch
            // layout the tabs are a segmented control (`FXU11`).
            const shown = n.children[n.active < n.children.length ? n.active : 0];
            const pane = cast(Pane) dock.layout.nodes[shown].pane;
            // Export's controls share the tabs' row when it has room (`FXU23`).
            exportControlsInStrip = false;
            shortModes = false;
            uint strip;
            if (touch)
            {
                uint[] parts = [touchSegments(b, labels, n.active, tabHitBase)];
                // The glob modes' short labels, if only they make it fit.
                const room = paneRect(pane).width - 2 - (segmentsWidth(labels) + 1);
                shortModes = room < exportControlsWidth(false);
                if (pane == Pane.export_ && room >= exportControlsWidth(shortModes))
                {
                    parts ~= b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(1)));
                    parts ~= exportControls(b);
                    exportControlsInStrip = true;
                }
                else // a row of their own in the pane: room for the long labels
                    shortModes = false;
                strip = b.add(Widget(kind: WidgetKind.row, padding: Insets(0, 1, 0, 1),
                    height: SizeSpec.fixed(rowCells), width: SizeSpec.grow(), children: parts));
            }
            else
                // The explorer's own ids, below the registry's issued slots
                // (`INP27`): one per tab, from `tabHitBase`.
                strip = tabStrip(b, labels, n.active,
                    idx == tabsNode ? HitBlock(tabHitBase, labels.length) : HitBlock.init);
            const vertical = dock.layout.nodes[dock.layout.root].axis == DockAxis.vertical;
            return b.add(Widget(kind: WidgetKind.column, children: [strip,
                paneView(b, pane, null, false, 0, stats)],
                width: n.extent > 0 && !vertical ? SizeSpec.fixed(n.extent) : SizeSpec.grow(),
                height: n.extent > 0 && vertical ? SizeSpec.fixed(n.extent) : SizeSpec.grow()));
        }
        // Panes are divided by a rule; the touch layout's is a gap.
        const vertical = n.axis == DockAxis.vertical;
        uint[] kids;
        foreach (i, ch; n.children)
        {
            if (i)
                kids ~= b.add(Widget(kind: WidgetKind.box, slot: Slot.border, paintBackground: !touch,
                    width: vertical ? SizeSpec.grow() : SizeSpec.fixed(1),
                    height: vertical ? SizeSpec.fixed(1) : SizeSpec.grow()));
            kids ~= renderNode(b, ch, stats);
        }
        return b.add(Widget(kind: vertical ? WidgetKind.column : WidgetKind.row, children: kids,
            width: SizeSpec.grow(), height: SizeSpec.grow()));
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
            case Pane.stats: content = statsView(b, stats, r.width, max(0, r.height)); break;
            case Pane.help: content = helpView(b, r); break;
            case Pane.export_: content = exportView(b, r); break;
        }
        // The dock's own geometry, clipped: a long row never spills into a neighbour.
        const body_ = b.add(Widget(kind: WidgetKind.column, children: [content], width: SizeSpec.fixed(max(0, r.width)),
            height: SizeSpec.fixed(max(0, r.height)), clipX: true));
        if (!header)
            return body_;
        const focused = (focus == Focus.tree && pane == Pane.tree) || (focus == Focus.side && pane != Pane.tree);
        if (touch)
        {
            // The tree's header: what it holds, and expanding or collapsing it all.
            const sz = ControlSize(rows: rowCells);
            const what = centred(b, b.add(Widget(kind: WidgetKind.text, slot: Slot.textSecondary,
                text: shown.found.members.length ? "Members" : "No members",
                textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.label, bold: true))));
            const fill = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
            const gap = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(1)));
            const head = b.add(Widget(kind: WidgetKind.row, width: SizeSpec.grow(), height: SizeSpec.fixed(rowCells),
                padding: Insets(0, 2, 0, 1), children: [what, fill,
                    touchChip(b, "Expand all", actionBase + Action.expandAll), gap,
                    touchChip(b, "Collapse all", actionBase + Action.collapseAll)]));
            return b.add(Widget(kind: WidgetKind.column, children: [head, body_],
                width: SizeSpec.fixed(max(0, r.width)), clipX: true));
        }
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
        // The connectors are hue's (`FXU9`), in both layouts.
        const glyphs = TreeGlyphs(closed: "", open: "", leaf: "");
        auto open = tv.open;
        auto data = &tree;
        // The rows from `tv.top`, one more for the part-row a fraction
        // uncovers, moved up by that fraction (`FXU10`).
        const first = cast(size_t) max(0, tv.top);
        const last = min(tv.rows.length, first + tv.bodyRows + 1);
        auto isOpen = (uint n) @safe => open.isOpen(data.nodes[n].value.path);
        if (!touch)
        {
            const rows = treeRows(b, tree, tv.rows[min(first, last) .. last], isOpen, tv.selectedNode, glyphs);
            auto vp = Widget(kind: WidgetKind.column, children: [rows], clipY: true,
                width: SizeSpec.grow(), height: SizeSpec.fixed(max(0, tv.bodyRows)));
            vp.childOffsetFracY = treeScroll.motion.frac;
            return withBar(b, b.add(vp), max(0, tv.bodyRows), treeScroll, 1, Bar.tree);
        }
        // Touch (`FXU11`): a dense list, each row `treeRowCells` tall, its
        // text centred, the selected one a rounded tint; the motion counts
        // rows, the paint cells. The connectors run on through the rows
        // above and below the text, so the lines join from item to item.
        uint guideRun(in Guide[] guides, bool below, bool topmost)
        {
            string line;
            foreach (d, g; guides)
            {
                const own = d + 1 == guides.length;
                if (own)
                    line ~= below ? (g == Guide.fork ? glyphs.guides.bar : glyphs.guides.space)
                        : topmost ? glyphs.guides.space : glyphs.guides.bar;
                else
                    line ~= g == Guide.continueBar ? glyphs.guides.bar : glyphs.guides.space;
            }
            return b.add(Widget(kind: WidgetKind.rich, spans: [TextSpan(line, Slot.gutter)],
                wrap: TextWrap.none));
        }
        // An even height centres the text on a cell's edge: a row more, the
        // whole moved half a row up.
        const even = (treeRowCells - 1) % 2 != 0;
        const around = even ? treeRowCells / 2 : (treeRowCells - 1) / 2;
        uint[] items;
        foreach (i; min(first, last) .. last)
        {
            const selected = tv.rows[i].node == tv.selectedNode;
            uint[] lines;
            foreach (_; 0 .. around)
                lines ~= guideRun(tv.rows[i].guides, false, i == 0);
            lines ~= treeRows(b, tree, tv.rows[i .. i + 1], isOpen, uint.max, glyphs);
            foreach (_; 0 .. around)
                lines ~= guideRun(tv.rows[i].guides, true, false);
            // The tint spans the row's whole height; the text sits in its middle.
            auto item = Widget(kind: WidgetKind.column, children: lines, width: SizeSpec.grow(),
                height: SizeSpec.fixed(treeRowCells), padding: Insets(0, 1, 0, 1),
                clipY: true, slot: Slot.selection, paintBackground: selected,
                decoration: selected ? Decoration(borderRadius: 8) : Decoration.init);
            if (even)
                item.childOffsetFracY = 0.5f;
            items ~= b.add(item);
        }
        // `tv.top` is the motion's whole row; its fraction is that much of a row.
        const cells = treeScroll.motion.frac * treeRowCells;
        const height = max(0, tv.bodyRows * treeRowCells);
        auto vp = Widget(kind: WidgetKind.column, children: items, clipY: true,
            width: SizeSpec.grow(), height: SizeSpec.fixed(height));
        vp.childOffset = Point(0, cast(int) floor(cells));
        vp.childOffsetFracY = cast(float)(cells - floor(cells));
        return withBar(b, b.add(vp), height, treeScroll, treeRowCells, Bar.tree);
    }

    /*
    `port`, `rows` cells tall, beside its overlay bar (`FXU14`): at `body`'s
    position, `unit` cells to each of its content's units, drawn when the
    content overflows the view, faded on the touch layout while it rests.
    */
    private uint withBar(ref Builder b, uint port, int rows, ref ScrollBody body, int unit, Bar which)
    {
        const content = body.content * unit;
        uint bar;
        if (content > rows && rows > 0)
        {
            const cells = (body.motion.whole + body.motion.frac) * cast(double) unit;
            const whole = floor(cells);
            bar = scrollbar(b, ScrollbarSpec(axis: ScrollAxis.vertical, content: content, viewport: rows,
                offset: cast(long) whole, offsetFrac: cast(float)(cells - whole),
                expandPercent: barHot == which || barGrab == which ? 100 : 0,
                fadePercent: touch ? body.bar.anim.fadePercent : 100, hitId: barHitBase + which), rows);
        }
        else
            bar = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(1)));
        return b.add(Widget(kind: WidgetKind.row, children: [port, bar], width: SizeSpec.grow(),
            height: SizeSpec.fixed(max(0, rows))));
    }

    // The widest visible row of the tree as drawn: guides, the folder or file
    // glyph, the name, and the badge after two spaces.
    private int treeWidth() const @safe
    {
        int widest;
        foreach (ref r; tv.rows)
        {
            const v = tree.nodes[r.node].value;
            widest = max(widest, cast(int)(r.depth * 3 + 3 + 2 + visibleWidth(v.label) + 2 + visibleWidth(v.badge)));
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
            // The cheat sheet's queries, each with a ▶ that tries it (`FXU19`).
            // Each fence where it was scrolled across to (`FXU25`).
            import sparkles.source_view.markdown : FenceScroll;

            FenceScroll[] scrolls;
            foreach (at, x; fenceX)
            {
                const whole = floor(x);
                scrolls ~= FenceScroll(at, cast(int) whole, 0, fx: smoothScroll ? cast(float)(x - whole) : 0);
            }
            o.fenceScrolls = scrolls;
            o.codeActionGlyph = " ▶";
            o.codeActionHeader = "Write";
            // The fences highlighted as the Export code is, a query's paths
            // and metacharacters as the editor draws them (`FXA3`, `FXL8`).
            // Highlighted once each: the help is built every frame.
            auto cache = &fenceLines;
            o.fenceRenderer = (const(char)[] lang, const(char)[] body_) @trusted {
                const key = text(lang, "\0", body_);
                if (auto hit = key in *cache)
                    return *hit;
                return (*cache)[key] = highlightCode(lang.idup, body_.idup);
            };
            content = viewMarkdownInto(b, helpDoc, o);
        }
        helpContent = content;
        // A column of margin at the left; the bar takes the right one.
        auto vp = Widget(kind: WidgetKind.column, children: [content], clipX: true, clipY: true,
            width: SizeSpec.grow(), height: SizeSpec.fixed(max(0, r.height)),
            padding: Insets(0, 0, 0, 1));
        vp.childOffset = Point(0, helpTop);
        vp.childOffsetFracY = helpScroll.motion.frac;
        return withBar(b, b.add(vp), max(0, r.height), helpScroll, 1, Bar.help);
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
                helpScroll.motion.scrollTo(max(0, *row - 2), helpScroll.limit);
    }

    // ---- export -------------------------------------------------------------

    // The Export tab (`FXE12`): the target and mode, then the code or the refusal.
    private uint exportView(ref Builder b, Rect r)
    {
        const e = currentExport;
        uint[] rows;
        // The header's parts are buttons too (`FXU10`): ◀ and ▶ step the
        // target, the glob mode cycles, and "copy" copies — what t/T, g and y do.
        uint part(TextSpan[] spans, size_t button = size_t.max)
        {
            auto w = Widget(kind: WidgetKind.rich, spans: spans);
            if (button != size_t.max)
                w.hitId = exportHitBase + button;
            return b.add(w);
        }
        int touchRows; // header rows `rowCells` tall
        if (touch)
        {
            // Touch (`FXU13`): the controls are on the tabs' row when it has
            // room (`FXU23`); here, on a narrow screen, the target and
            // copying on one row and Nix's glob mode on the next.
            if (!exportControlsInStrip)
            {
                uint[] line = exportTargetControls(b);
                line ~= b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
                if (e.ok)
                    line ~= touchChip(b, "Copy", exportHitBase + 3);
                rows ~= b.add(Widget(kind: WidgetKind.row, children: line, width: SizeSpec.grow(),
                    height: SizeSpec.fixed(rowCells)));
                ++touchRows;
                if (exportTarget == Target.nix)
                {
                    rows ~= b.add(Widget(kind: WidgetKind.row, height: SizeSpec.fixed(rowCells),
                        children: [nixModeSegments(b)]));
                    ++touchRows;
                }
                rows ~= b.add(Widget(kind: WidgetKind.text, text: ""));
            }
        }
        else
        {
            uint[] head = [part([TextSpan(" ◀ ", Slot.muted)], 0),
                part([TextSpan(targetName(exportTarget), Slot.accentPrimary, TextStyle(bold: true))]),
                part([TextSpan(" ▶", Slot.muted)], 1), part([TextSpan("  t/T target", Slot.muted)])];
            if (exportTarget == Target.nix)
                head ~= part([TextSpan("   globs: ", Slot.muted), TextSpan(text(nixGlobs), Slot.code),
                    TextSpan(" (g)", Slot.muted)], 2);
            if (e.ok)
                head ~= part([TextSpan("   ", Slot.muted), TextSpan("copy", Slot.accentPrimary),
                    TextSpan(" (y)", Slot.muted)], 3);
            rows ~= b.add(Widget(kind: WidgetKind.row, children: head));
            rows ~= b.add(Widget(kind: WidgetKind.text, text: ""));
        }
        // The header's cells: the touch controls are `rowCells` tall.
        const headRows = cast(long) rows.length;
        const headCells = headRows + touchRows * (rowCells - 1);
        long bodyCells = 0;
        if (!e.ok)
        {
            rows ~= b.add(Widget(kind: WidgetKind.rich, wrap: TextWrap.greedy, width: SizeSpec.fixed(max(10, r.width - 2)),
                spans: [TextSpan(" ✗ ", Slot.error), TextSpan(e.reason, Slot.error)]));
            if (e.span.end > e.span.start && outcome.query.ok)
                rows ~= b.add(Widget(kind: WidgetKind.rich, spans: [TextSpan("   in the query: ", Slot.muted),
                    TextSpan(query.text[min(e.span.start, $) .. min(e.span.end, $)], Slot.warn)]));
            bodyCells = cast(long) rows.length - headRows;
        }
        else
        {
            // Only the lines that show, and the one a fraction uncovers
            // (`FXU20`): the rows above them are a gap of their height.
            const lines = exportLines;
            const top = cast(long) exportScroll.motion.whole - headCells;
            const first = cast(size_t) min(lines.length, max(0, top));
            const last = cast(size_t) min(lines.length, max(0, top + r.height + 1));
            if (first > 0)
                rows ~= b.add(Widget(kind: WidgetKind.box, height: SizeSpec.fixed(cast(int) first)));
            // The lines scroll across as a block, under a header that stays
            // (`FXU22`): a snapshot's paths, or a long command, can be wider
            // than any pane.
            uint[] body_;
            foreach (line; lines[first .. last])
                body_ ~= b.add(Widget(kind: WidgetKind.rich, width: SizeSpec.rigid_,
                    spans: line.length ? cast(TextSpan[]) line : [TextSpan(" ")]));
            const across = max(0, r.width - 2);
            exportScrollX.content = exportWidth;
            exportScrollX.viewport = across;
            auto block = Widget(kind: WidgetKind.column, children: body_, clipX: true,
                width: SizeSpec.fixed(across));
            block.childOffset = Point(cast(int) exportScrollX.motion.whole, 0);
            block.childOffsetFracX = exportScrollX.motion.frac;
            rows ~= b.add(block);
            bodyCells = lines.length;
        }
        auto vp = Widget(kind: WidgetKind.column, children: rows, clipX: true, clipY: true,
            width: SizeSpec.grow(), height: SizeSpec.fixed(max(0, r.height)),
            padding: Insets(0, 0, 0, 1));
        exportScroll.content = headCells + bodyCells;
        exportScroll.viewport = r.height;
        vp.childOffset = Point(0, cast(int) exportScroll.motion.whole);
        vp.childOffsetFracY = exportScroll.motion.frac;
        return withBar(b, b.add(vp), max(0, r.height), exportScroll, 1, Bar.export_);
    }

    // ---- stats -------------------------------------------------------------

    /// The Stats tab's lines, `[key, value]`; an empty key is a heading
    /// (`statsRows`, shared with `stats`, `FXC2`).
    string[2][] statsLines() const @safe
        => statsRows(shown, outcome, touch ? "" : ": press i in the tree", sendLines());

    /// The Stats tab's lines without the Send section: what `stats` prints.
    string[2][] statsLinesAlone() const @safe
        => statsRows(shown, outcome, touch ? "" : ": press i in the tree");

    /// The value of name `i`, as shown and copied.
    string nameValue(size_t i) const @safe => nameValueOf(shown, i);

    /// The Send section's lines (`FXS3`–`FXS5`, `FXS8`); a key of `sendControls`
    /// marks where the touch layout's buttons go.
    private string[2][] sendLines() const @safe
    {
        string[2][] rows = [["", ""], ["", "send"]];
        final switch (sending.stage)
        {
            case SendStage.idle:
                rows ~= ["send", touch ? "these files with iroh" : "s sends these files with iroh"];
                break;
            case SendStage.asking:
                rows ~= ["files", text(sending.sent.files.length, " (", humanBytes(sending.sent.bytes), ")")];
                if (sending.sent.links)
                    rows ~= ["left out", text(sending.sent.links, sending.sent.links == 1 ? " link" : " links")];
                rows ~= ["iroh", sending.sent.collection];
                rows ~= ["ask", touch ? "anyone with the ticket can fetch them"
                    : "anyone with the ticket can fetch them · ⏎ send · Esc cancel"];
                break;
            case SendStage.running:
                rows ~= ["state", sending.phaseText];
                if (const cmd = sending.receiveCommand)
                {
                    rows ~= ["receive", commandCopied ? cmd ~ "  ✓ copied" : cmd];
                    rows ~= ["peers", text(sending.state.peers, " connected · ", sending.state.requests,
                        " requests · ", humanBytes(sending.state.bytesSent), " sent")];
                    if (shareProblem.length)
                        rows ~= ["share", shareProblem];
                }
                if (query.text != sending.sent.query)
                    rows ~= ["sent query", sending.sent.query];
                if (!touch)
                    rows ~= ["keys", sending.receiveCommand.length ? "y copy · x stop" : "x stop"];
                break;
            case SendStage.unavailable:
                rows ~= ["state", sending.note];
                break;
        }
        rows ~= [sendControls, ""];
        return rows;
    }

    private enum string sendControls = "\x01";

    /// The Stats tab's name lines (`FXS2`): `statsHitBase + i`.
    enum size_t statsHitBase = tabHitBase + 256;
    /// Send's buttons on the touch layout: `sendHitBase + SendButton`.
    enum size_t sendHitBase = statsHitBase + 32;

    /// Send's buttons.
    enum SendButton : ubyte
    {
        send,    /// ask, or confirm
        cancel,  ///
        copy,    /// the receive command
        stop,    ///
        share,   /// the receive command, to the platform's share sheet
    }

    private uint statsView(ref Builder b, in string[2][] rows, int width, int height)
    {
        uint[] out_;
        const room = max(8, width - statsKeyWidth - 1);
        // The cells drawn so far: a line is one, a row of touch buttons its
        // target's height. What would not fit is not drawn, nor hit: a
        // column taller than its pane squeezes its lines over each other.
        int used;
        bool fits(int cells) => used + cells <= height;
        void put(uint row, int cells)
        {
            out_ ~= row;
            used += cells;
        }

        foreach (ref kv; rows)
        {
            if (!fits(1))
                break;
            if (kv[0] == sendControls)
            {
                // Every layout has the buttons: a pointer clicks what a
                // finger taps, and the keys stay beside them (`FXS4`).
                if (fits(rowCells))
                    if (auto chips = sendChips(b))
                        put(b.add(Widget(kind: WidgetKind.row, padding: Insets(0, 1, 0, 0), children: chips)),
                            rowCells);
                continue;
            }
            if (kv[0].length == 0)
            {
                put(b.add(Widget(kind: WidgetKind.text, text: " " ~ kv[1], slot: Slot.chromeAccent)), 1);
                continue;
            }
            Slot s = Slot.code;
            if (kv[0] == "members")
                s = Slot.accentPrimary;
            else if ((kv[0] == "unreadable" || kv[0] == "state") && kv[1] != "0")
                s = kv[0] == "state" && sending.stage == SendStage.running ? Slot.success : Slot.error;
            else if ((kv[0] == "empty dirs" && kv[1] != "0") || kv[0] == "sent query" || kv[0] == "iroh skips"
                    || kv[0] == "left out" || kv[0] == "ask")
                s = Slot.warn;
            else if (kv[0] == "ids" || kv[0] == "send" || kv[0] == "keys")
                s = Slot.muted;
            // A name's line is chosen, copied and marked (`FXS2`).
            size_t name = size_t.max;
            foreach (i, k; nameKeys)
                if (k == kv[0] && sending.stage != SendStage.asking)
                    name = i;
            const chosen = name != size_t.max && focus == Focus.side && name == nameSel;
            string value = kv[1];
            if (name != size_t.max && name == copiedName)
                value ~= "  ✓ copied";
            // A long value wraps across lines, whole, rather than being cut.
            foreach (k, piece; wrapCells(value, room))
            {
                if (!fits(1))
                    break;
                const key = b.add(Widget(kind: WidgetKind.text, text: k ? "" : " " ~ kv[0],
                    slot: chosen ? Slot.accentPrimary : Slot.muted, width: SizeSpec.fixed(statsKeyWidth)));
                const val = b.add(Widget(kind: WidgetKind.text, text: piece, slot: s,
                    textStyle: TextStyle(bold: chosen)));
                put(b.add(Widget(kind: WidgetKind.row, children: [key, val],
                    hitId: name != size_t.max ? statsHitBase + name : 0)), 1);
            }
            // Touch: the ids are a button away, under their line (`FXU13`).
            if (touch && kv[0] == "ids" && fits(rowCells))
                put(b.add(Widget(kind: WidgetKind.row, padding: Insets(0, 1, 0, 0), children: [
                    touchChip(b, "Compute ids", actionBase + Action.computeIds)])), rowCells);
        }
        return b.add(Widget(kind: WidgetKind.column, children: out_, width: SizeSpec.grow()));
    }

    // Send's buttons for its stage, on the touch layout (`FXS3`, `FXS4`).
    private uint[] sendChips(ref Builder b)
    {
        final switch (sending.stage)
        {
            case SendStage.idle, SendStage.unavailable:
                return [touchChip(b, "Send", sendHitBase + SendButton.send)];
            case SendStage.asking:
                return [touchChip(b, "Send", sendHitBase + SendButton.send), gapCells(b, 1),
                    touchChip(b, "Cancel", sendHitBase + SendButton.cancel)];
            case SendStage.running:
                uint[] chips;
                if (sending.receiveCommand.length)
                {
                    chips ~= [touchChip(b, "Copy", sendHitBase + SendButton.copy), gapCells(b, 1)];
                    // Where the platform has a share sheet (Android's).
                    if (shareText !is null)
                        chips ~= [touchChip(b, "Share", sendHitBase + SendButton.share), gapCells(b, 1)];
                }
                return chips ~ touchChip(b, "Stop", sendHitBase + SendButton.stop);
        }
    }

    /// The name chosen with Up and Down (`FXS2`), and the one last copied.
    size_t nameSel;
    /// ditto
    size_t copiedName = size_t.max;
    /// Send's state (`FXS3`–`FXS8`).
    Sending sending;
    /// The receive command of the send running was copied (`FXS4`).
    bool commandCopied;
    /// Why the share sheet could not take the command, when it could not.
    string shareProblem;

    /// Copies name `i` to the clipboard, and marks its line (`FXS2`).
    void copyName(H)(ref H h, size_t i)
    {
        if (!shown.hasIds || i >= nameKeys.length)
            return;
        static if (__traits(compiles, h.clipboard("")))
            h.clipboard(nameValue(i));
        copiedName = i;
        nameSel = i;
    }

    /// Send's button or key `button` (`FXS3`, `FXS4`).
    void sendAction(H)(ref H h, SendButton button)
    {
        final switch (button)
        {
            case SendButton.send:
                if (sending.stage == SendStage.asking)
                {
                    commandCopied = false; // a new send, a new ticket
                    shareProblem = null;
                    return sending.confirm();
                }
                if (sending.stage == SendStage.running)
                    return;
                if (!shown.hasIds && !root.inMemory)
                {
                    idsRequested = true;
                    refresh();
                }
                sending.ask(shown, root, query.text);
                break;
            case SendButton.cancel:
                sending.cancel();
                break;
            case SendButton.copy:
                if (const cmd = sending.receiveCommand)
                {
                    static if (__traits(compiles, h.clipboard("")))
                        h.clipboard(cmd);
                    commandCopied = true;
                }
                break;
            case SendButton.stop:
                sending.stop();
                break;
            case SendButton.share:
                if (const cmd = sending.receiveCommand)
                    if (shareText !is null)
                        shareProblem = shareText(cmd);
                break;
        }
    }

    // The Stats tab's keys: Up and Down choose a name, `y` copies it or the
    // receive command, `s` sends, Enter confirms, Escape cancels, `x` stops.
    private void statsKey(H)(ref H h, in KeyEvent k)
    {
        switch (k.key)
        {
            case Key.up: nameSel = nameSel ? nameSel - 1 : 0; break;
            case Key.down: nameSel = min(nameSel + 1, nameKeys.length - 1); break;
            case Key.enter:
                if (sending.stage == SendStage.asking)
                    sendAction(h, SendButton.send);
                break;
            case Key.char_:
                switch (k.ch)
                {
                    case 'y':
                        if (sending.receiveCommand.length)
                            sendAction(h, SendButton.copy);
                        else
                            copyName(h, nameSel);
                        break;
                    case 's': sendAction(h, SendButton.send); break;
                    case 'x': sendAction(h, SendButton.stop); break;
                    default: break;
                }
                break;
            default: break;
        }
    }

    /// Whether the Stats tab is the one showing.
    bool statsShown() const @safe => !helpShown && !exportShown;

    // A bordered pane with a caption; the focused one draws its focus border.
    private uint panel(ref Builder b, string caption, int bodyRows, uint[] body_, bool focused)
    {
        // Opaque, a cell of space each side: the rule stops short of the caption
        // rather than running under it, on a pixel target as on a terminal.
        const cap = b.add(Widget(kind: WidgetKind.text, text: " " ~ caption ~ " ",
            slot: focused ? Slot.accentPrimary : Slot.muted, textStyle: TextStyle(bold: true),
            paintBackground: true));
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
            (in PasteEvent p) => onPaste(p),
            (in WheelEvent w) => onWheel(w),
            (in PointerEvent p) => onPointer(h, p),
            (in _) {},
        );
    }

    // A paste goes into the query, whole (`EDI4`): the user's own, or the
    // answer to the query's clipboard read (`EDY5`).
    private void onPaste(in PasteEvent p)
    {
        if (focus != Focus.query && !p.request)
        {
            pasteBuf = null;
            return;
        }
        pasteBuf ~= p.text[];
        if (!p.last)
            return;
        if (query.paste(pasteBuf, p.request).changed)
            refresh();
        pasteBuf = null;
    }

    private char[] pasteBuf; // a paste's chunks, until its last

    // The dock's top edge on screen: the title and the query pane above it.
    private int dockTop() const @safe => dockY;

    private int dockY = 5; // where the last frame put the dock's top row

    private int lastHeight = 30;

    /// The rows one wheel notch scrolls.
    enum notchRows = 3;

    // The wheel, and a finger's drag and fling, scroll the pane where they
    // began (`DCK7`, `FXU10`) and leave the tree's cursor where it is. A
    // precise distance (a finger, a trackpad) moves the content exactly; a
    // notch eases it `notchRows` on.
    private void onWheel(in WheelEvent w)
    {
        auto s = scrollAt(w.pos);
        // Across, in the Export tab (`FXU22`): a finger or a trackpad moving
        // more across than down, or a wheel turned with Shift.
        const acrossBy = w.exactX != 0 ? w.exactX : !w.precise && w.mods.shift ? w.exactY : 0;
        // The axis is the gesture's, chosen as it begins and kept to its end
        // (its fling's too, `SCV12`): a finger's path is never quite straight,
        // and an event at a time would hand a swipe across to the page each
        // time it dipped (`FXU25`).
        if (w.begins || !gestureAxisSet)
        {
            gestureAxisSet = acrossBy != 0 || w.exactY != 0;
            gestureAcross = acrossBy != 0 && (w.mods.shift || abs(w.exactX) > abs(w.exactY));
            gestureFence = size_t.max;
            if (gestureAcross && s is &helpScroll)
                foreach (ref f; fenceViews)
                    if (inside(f.box, w.pos))
                        gestureFence = f.at;
        }
        // ... over a help fence wider than its box, its frame included, that
        // fence (`FXU25`).
        if (gestureAcross && gestureFence != size_t.max)
        {
            foreach (ref f; fenceViews)
                if (f.at == gestureFence)
                {
                    const most = max(0, f.content - f.rect.width);
                    const by = w.precise ? acrossBy : acrossBy * notchRows * 2;
                    fenceX[f.at] = min(cast(double) most, max(0.0, fenceX.get(f.at, 0) + by));
                }
            return;
        }
        if (s is &exportScroll && gestureAcross)
        {
            WheelEvent x = w;
            x.fdy = w.precise ? acrossBy : acrossBy * notchRows * 2;
            exportScrollX.scroll(x);
            return;
        }
        if (w.exactY == 0 || s is null)
            return;
        WheelEvent v = w;
        if (!w.precise)
            v.fdy = w.exactY * notchRows;
        else if (s is &treeScroll) // a finger moves cells; the tree counts rows
            v.fdy = w.exactY / treeRowCells;
        s.scroll(v);
    }

    private static bool inside(in Rect r, Point p) @safe pure nothrow @nogc
        => p.x >= r.x && p.x < r.x + r.width && p.y >= r.y && p.y < r.y + max(1, r.height);

    // The scroll body behind bar `which`, and the cells to its content unit.
    private ScrollBody* barBody(Bar which, out int unit) return @safe
    {
        unit = which == Bar.tree ? treeRowCells : 1;
        final switch (which)
        {
            case Bar.tree: return &treeScroll;
            case Bar.help: return &helpScroll;
            case Bar.export_: return &exportScroll;
        }
    }

    // A press on bar `which` at row `y`: on the thumb it takes it where it
    // is; elsewhere the thumb's middle comes under the pointer (`FXU14`).
    private void grabBar(Bar which, int y)
    {
        int unit;
        auto body = barBody(which, unit);
        const r = barRects[which];
        const at = cast(long) floor((body.motion.whole + body.motion.frac) * unit);
        const t = scrollbarThumb(body.content * unit, r.height, at, r.height);
        barGrab = which;
        body.bar.grabbed = true;
        if (y >= r.y + t.start && y < r.y + t.start + t.extent)
            grabAt = y - (r.y + t.start);
        else
        {
            grabAt = t.extent / 2;
            dragBar(y);
        }
    }

    // The held thumb dragged to row `y`: the view goes where it puts it.
    private void dragBar(int y)
    {
        int unit;
        auto body = barBody(cast(Bar) barGrab, unit);
        const r = barRects[barGrab];
        const content = body.content * unit;
        const t = scrollbarThumb(content, r.height, 0, r.height);
        const span = r.height - t.extent, most = content - r.height;
        if (span <= 0 || most <= 0)
            return;
        const f = min(1.0, max(0.0, cast(double)(y - grabAt - r.y) / span));
        body.barTo(f * most / unit);
    }

    // With a pointer: its shape, and the bar it is over (`FXU15`, `FXU14`).
    private void hover(H)(ref H h, in PointerEvent p)
    {
        barHot = noBar;
        PointerShape want = PointerShape.default_;
        if (p.action == PointerAction.move)
        {
            foreach (i, r; barRects)
                if (r.height > 0 && inside(r, p.pos))
                    barHot = cast(int) i;
            if (queryRect.height > 0 && inside(queryRect, p.pos))
                want = PointerShape.text;
            foreach (ref hit; buttons ~ tryHits)
                if (inside(hit.rect, p.pos))
                    want = PointerShape.pointer;
        }
        if (want != shape)
        {
            shape = want;
            h.pointerShape(want);
        }
    }

    private void onPointer(H)(ref H h, in PointerEvent p)
    {
        // A held bar follows the pointer, and lets go with it (`FXU14`).
        if (barGrab != noBar)
        {
            if (p.action == PointerAction.drag || p.action == PointerAction.move)
                return dragBar(p.pos.y);
            if (p.action == PointerAction.release || p.action == PointerAction.leave)
            {
                int unit;
                barBody(cast(Bar) barGrab, unit).bar.grabbed = false;
                barGrab = noBar;
            }
            return;
        }
        if (p.action == PointerAction.move || p.action == PointerAction.leave)
            return hover(h, p);
        if (p.action != PointerAction.press || p.button != PointerButton.left)
            return;
        // With a pointer, a press on a bar takes its thumb (`FXU14`).
        if (!touch)
            foreach (i, r; barRects)
                if (r.height > 0 && inside(r, p.pos))
                    return grabBar(cast(Bar) i, p.pos.y);
        // A ▶ the last frame drew runs its block (`FXT2`).
        foreach (ref hit; tryHits)
            if (inside(hit.rect, p.pos))
                foreach (i, ref t; tries)
                    if (t.at == hit.at)
                        return runTry(i);
        // A tab shows its pane; an Export button does what its key does
        // (`FXU10`); the touch layout's buttons do theirs (`FXU11`, `FXU13`).
        foreach (ref hit; buttons)
            if (inside(hit.rect, p.pos))
            {
                // A name's line copies it; Send's buttons (`FXS2`–`FXS4`).
                if (hit.at >= sendHitBase && hit.at <= sendHitBase + SendButton.max)
                {
                    focus = Focus.side;
                    return sendAction(h, cast(SendButton)(hit.at - sendHitBase));
                }
                if (hit.at >= statsHitBase && hit.at < statsHitBase + nameKeys.length)
                {
                    focus = Focus.side;
                    return copyName(h, hit.at - statsHitBase);
                }
                if (hit.at >= actionBase)
                    return touchAction(cast(size_t)(hit.at - actionBase));
                focus = Focus.side;
                if (hit.at < exportHitBase)
                {
                    auto g = &dock.layout.nodes[tabsNode];
                    if (hit.at - tabHitBase < g.children.length)
                        g.active = cast(uint)(hit.at - tabHitBase);
                }
                else
                    exportAction(h, hit.at - exportHitBase);
                return;
            }
        // Above the dock: the query, and on a phone its keyboard; on its
        // lines, the caret goes where the click is (`FXU15`).
        if (p.pos.y < dockTop)
        {
            focus = Focus.query;
            keyboardWanted = true;
            if (queryRect.height > 0 && inside(queryRect, p.pos))
            {
                const at = queryOffsetAt(p.pos);
                cast(void) query.run(EditCommand.setRange(at, at));
            }
            return;
        }
        // The pane under the press, by this frame's arrangement (`FXU18`).
        // Not the dock's router: it keeps a press's pane until the release,
        // which a tap here ends without, so every later press went to the
        // first pane pressed.
        const local = Point(p.pos.x, p.pos.y - dockTop);
        foreach (ref f; dock.frames.panes)
        {
            if (!inside(f.rect, local))
                continue;
            if (f.pane != Pane.tree)
            {
                focus = Focus.side;
                // A cheat sheet snippet or its ▶ (`FXU19`): which one is the
                // laid-out text's to say, so the next `paint` resolves it.
                if (helpShown)
                {
                    cheatAt = p.pos;
                    cheatPending = true;
                    h.requestFrame();
                }
                return;
            }
            focus = Focus.tree;
            // The row under the cell's middle in the pane's body, the rows
            // moved up by the scroll's fraction, each `treeRowCells` tall.
            const y = local.y - f.rect.y;
            const row = tv.top + cast(long) floor(
                (treeScroll.motion.frac * treeRowCells + y + 0.5) / treeRowCells);
            if (row >= 0 && row < cast(long) tv.rows.length)
            {
                const wasSel = tv.sel == row;
                tv.sel = row;
                // A second click opens or closes; a tap on a directory at once (`FXU13`).
                const dirTap = touch && tree.nodes[tv.rows[cast(size_t) row].node].value.isDir;
                if ((wasSel || dirTap) && treeActivate(tv, tree, &keyOf) == TreeStep.rebuild)
                    reflatten();
            }
            return;
        }
    }

    private void onKey(H)(ref H h, in KeyEvent k)
    {
        lastHeight = h.size.height;
        // Escape, or Android's Back (`INP13`): the help, then a tutorial's
        // tree, then the explorer itself; with no keyboard, from any focus.
        const back = isDismiss(k);
        if (k.key == Key.f1 || (back && helpShown && (focus == Focus.side || touch)))
            return toggleHelp();
        // Asked to send: Escape says no (`FXS3`).
        if (back && sending.stage == SendStage.asking)
            return sending.cancel();
        if (back && root.inMemory)
        {
            root = dir; // FXT4: back to the directory
            refresh();
            return;
        }
        if (back || (k.key == Key.char_ && k.ch == 'c' && k.mods.ctrl))
        {
            sending.stop(); // a send ends with the explorer, its store removed
            return h.quit();
        }
        if (k.key == Key.tab)
        {
            focus = cast(Focus)((focus + (k.mods.shift ? 2 : 1)) % 3);
            return;
        }
        final switch (focus)
        {
            case Focus.query: return queryKey(h, k);
            case Focus.tree: return treeKey(k);
            case Focus.side: return sideKey(h, k);
        }
    }

    // The query's keys are the backend's (`EDK1`): a window's copy, cut and
    // paste chords, with the clipboard the host has (`EDY5`); a read is
    // answered later by a paste carrying its request.
    private void queryKey(H)(ref H h, in KeyEvent k)
    {
        import sparkles.ui.editor.field : forwardClipboard, FieldSetup;
        import sparkles.ui.editor.keys : EditorTarget, windowTarget;
        import sparkles.ui_app.backend : Backend;
        import sparkles.ui_app.host : canReadClipboard;

        FieldSetup setup;
        setup.target = h.backend == Backend.gui ? windowTarget : EditorTarget.terminal;
        setup.clipboardWrite = __traits(compiles, h.clipboard(""));
        static if (canReadClipboard!H)
            setup.clipboardRead = h.capabilities.clipboardRead;
        setup.applyTo(query);
        scope (exit)
            forwardClipboard(query, h);
        queryKeyIn(k);
    }

    private void queryKeyIn(in KeyEvent k)
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

    // The Export tab's keys: the target, Nix's glob mode, scrolling, copying.
    private void exportKey(H)(ref H h, in KeyEvent k)
    {
        const page = max(1, paneRect(Pane.export_).height - 2);
        switch (k.key)
        {
            case Key.up: exportScroll.by(-1); break;
            case Key.down: exportScroll.by(1); break;
            case Key.pageUp: exportScroll.by(-page); break;
            case Key.pageDown: exportScroll.by(page); break;
            case Key.char_:
                if (k.ch == 'T' || k.ch == 't' || k.ch == 'g' || k.ch == 'y')
                    exportAction(h, k.ch == 'T' ? 0 : k.ch == 't' ? 1 : k.ch == 'g' ? 2 : 3);
                break;
            default: break;
        }
    }

    // A touch layout button (`FXU11`, `FXU13`).
    private void touchAction(size_t action)
    {
        if (action >= Action.insert)
        {
            const i = action - Action.insert;
            if (i >= chipTexts.length)
                return;
            focus = Focus.query;
            const inserted = chipTexts[i][1];
            bool changed = query.insert(inserted, true).changed;
            // A pair leaves the caret between its halves.
            if (inserted == "()" || inserted == "\"\"")
                changed |= query.key(KeyEvent(Key.left)).changed;
            if (changed)
                refresh();
            return;
        }
        final switch (cast(Action) action)
        {
            case Action.expandAll, Action.collapseAll:
                focus = Focus.tree;
                tv.open = action == Action.expandAll ? typeof(tv.open).allOpen : typeof(tv.open).allClosed;
                reflatten();
                break;
            case Action.computeIds:
                idsRequested = true;
                refresh();
                break;
            case Action.globShim, Action.globExpand, Action.globRefuse:
                focus = Focus.side;
                nixGlobs = cast(NixGlobs)(action - Action.globShim);
                exportStale = true;
                break;
            case Action.clear:
                focus = Focus.query;
                query = EditorField.make("");
                refresh();
                break;
            case Action.backspace:
                focus = Focus.query;
                if (query.key(KeyEvent(Key.backspace)).changed)
                    refresh();
                break;
            case Action.insert:
                break;
        }
    }

    // The Export tab's four actions, by key or by its button: the previous
    // target, the next, Nix's next glob mode, and copying the code.
    private void exportAction(H)(ref H h, size_t action)
    {
        size_t at;
        foreach (i, t; targets)
            if (t == exportTarget)
                at = i;
        if (action <= 1)
        {
            exportTarget = targets[(at + (action == 1 ? 1 : targets.length - 1)) % targets.length];
            exportStale = true;
            exportScroll.motion.jumpTo(0, 0);
            exportScrollX.motion.jumpTo(0, 0);
        }
        else if (action == 2 && exportTarget == Target.nix)
        {
            nixGlobs = cast(NixGlobs)((nixGlobs + 1) % (NixGlobs.max + 1));
            exportStale = true;
        }
        else if (action == 3 && currentExport.ok)
        {
            static if (__traits(compiles, h.clipboard(currentExport.code)))
                h.clipboard(currentExport.code);
        }
    }

    private void sideKey(H)(ref H h, in KeyEvent k)
    {
        if (k.key == Key.left || k.key == Key.right)
        {
            // The right group's tabs, whatever pane the dock thinks has focus.
            auto g = &dock.layout.nodes[tabsNode];
            const n = cast(uint) g.children.length;
            g.active = (g.active + (k.key == Key.right ? 1 : n - 1)) % n;
            return;
        }
        if (exportShown)
            return exportKey(h, k);
        if (statsShown)
            return statsKey(h, k);
        const page = max(1, paneRect(Pane.help).height - 2);
        switch (k.key)
        {
            case Key.up: helpScroll.by(-1); break;
            case Key.down: helpScroll.by(1); break;
            case Key.pageUp: helpScroll.by(-page); break;
            case Key.pageDown: helpScroll.by(page); break;
            case Key.home: helpScroll.motion.scrollTo(0, helpScroll.limit); break;
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

/// `s` in pieces of at most `cells` cells each, split between code points:
/// a value wraps whole rather than being cut (`FXS4`). Never empty.
string[] wrapCells(string s, int cells) @safe
{
    import std.utf : stride;

    string[] pieces;
    size_t start, at;
    long width;
    while (at < s.length)
    {
        const n = stride(s, at);
        const w = visibleWidth(s[at .. at + n]);
        if (width + w > cells && at > start)
        {
            pieces ~= s[start .. at];
            start = at;
            width = 0;
        }
        width += w;
        at += n;
    }
    pieces ~= s[start .. $];
    return pieces;
}

///
@("fileset_explorer.wrapCells")
@safe unittest
{
    assert(wrapCells("", 4) == [""]);
    assert(wrapCells("abcdefghij", 4) == ["abcd", "efgh", "ij"]);
    assert(wrapCells("éé✓é", 2) == ["éé", "✓é"]);
}

/// A cheat sheet snippet (`FXU19`): its query, and the bytes its code span
/// (pieces and all) covers in the help's source.
struct Cheat
{
    string query; ///
    size_t start; ///
    size_t end;   ///
}

/**
The snippets of every table whose header reads "Write", the cheat sheet's:
each code span of a body cell in that column is a query, a `\|` in it a pipe.
*/
Cheat[] cheatSnippets(in MdDoc doc, string src) @safe
{
    import std.array : replace;
    import std.string : strip;
    import sparkles.syntax.md.model : MdBlock, MdBlockKind, MdInlineKind;

    Cheat[] out_;
    void walk(in MdBlock blk)
    {
        foreach (ref c; blk.children)
            walk(c);
        if (blk.kind != MdBlockKind.table || blk.children.length < 2)
            return;
        size_t col = size_t.max;
        foreach (ci, ref cell; blk.children[0].children)
            if (src[cell.span.start .. cell.span.end].strip == "Write")
                col = ci;
        if (col == size_t.max)
            return;
        foreach (ref row; blk.children[1 .. $])
        {
            if (col >= row.children.length)
                continue;
            const inls = row.children[col].inlines;
            for (size_t i = 0; i < inls.length; ++i)
            {
                if (inls[i].kind != MdInlineKind.codeSpan)
                    continue;
                // The run of pieces a `\|` cut it into, a backslash apart.
                size_t j = i;
                while (j + 1 < inls.length && inls[j + 1].kind == MdInlineKind.codeSpan
                    && inls[j + 1].span.start <= inls[j].span.end + 1)
                    ++j;
                const a = inls[i].span.start, z = inls[j].span.end;
                out_ ~= Cheat(src[a .. z].replace(`\|`, "|").strip, a, z);
                i = j;
            }
        }
    }
    walk(doc.root);
    return out_;
}

/// FXU19: the cheat sheet's snippets, one per code span of its Write column,
/// `\|` a pipe.
@("fileset_explorer.FXU19.cheatSnippets")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.algorithm.iteration : map;
    import std.array : array;

    auto app = new ExplorerApp(Root(literal: "a.d = x\n", name: "t"), "**");
    if (app.helpDoc.root.children.length == 0)
        return; // no markdown grammar: the help is its text
    const qs = app.cheats.map!(c => c.query).array;
    assert(qs.canFind("*.d") && qs.canFind("src/**") && qs.canFind("a | b"), qs.text);
    assert(qs.canFind("p || q") && qs.canFind("fileFilter(hasExt(d))"), qs.text);
    assert(!qs.canFind("Tab"), "the keys table has no Write column");
}

/// Where a frame drew a fence's body viewport, the fence (its body's start)
/// and its lines' widest, in cells (`FXU25`).
struct FenceView
{
    Rect rect;   ///
    size_t at;   ///
    int content; ///
    Rect box;    /// the whole fence, its frame included: where a gesture takes it
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
        // A path reads as a string, bare or quoted; its metacharacters apart (`FXL8`).
        case TokenKind.path: return Slot.success;
        case TokenKind.globMeta: return Slot.accentSecondary;
        case TokenKind.escape: return Slot.link;
        case TokenKind.operator: return Slot.warn;
        case TokenKind.function_: return Slot.info;
        case TokenKind.predicate: return Slot.accentPrimary;
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
    assert(slots == [Slot.success, Slot.inherit, Slot.warn, Slot.inherit, Slot.success, Slot.inherit,
        Slot.muted], text(slots));

    auto marked = highlight(editorLineSpans(EditorState.create(src), 0, o), q.tokens, Span(4, 7));
    foreach (s; marked)
        if (s.text == "\"b\"")
            assert(s.slot == Slot.error);
}
