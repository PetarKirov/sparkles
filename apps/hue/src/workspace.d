// The split-pane workspace (`XPL2`) — hue's one interactive terminal shell.
// The explorer tree is a left pane, the document viewer the right pane, both
// composed into one frame by one event loop: there are no `runX() → runY()`
// full-screen transitions any more. A file target starts with the tree
// hidden (`e` shows it, revealed at the file); a directory target starts in
// the tree.
//
// The panes stay in sync (`XPL3`/`XPL4`): opening a file highlights it in
// the tree, and `[`/`]` walk the tree's visible files, updating both panes.
//
// Posix-only (the raw-mode loop is).
module workspace;

version (Posix):

import core.time : msecs;
import std.path : dirName;

import sparkles.base.term_control : PointerShape;
import sparkles.syntax : HighlightEvent, LabelSet, resolveTheme, RgbColor,
    Theme, toRgb;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.tui : CellStyle, Color, Grid, PosixEvents, Terminal,
    TerminalOptions;
import sparkles.tui.input : EndOfInput, Event, isEndOfInput, Key, KeyEvent,
    match, PointerAction, PointerButton, PointerEvent, ResizeEvent, WheelEvent;
import sparkles.ui.geometry : Point;
import sparkles.ui.state : SplitState;
import sparkles.ui.style : Slot;

import ansi_model : BackgroundMode;
import explorer : ExplorerTui;
import gui_preview : PreviewModel;
import sparkles.twoslash.protocol : TwoslashReturn;
import tui : PreviewTui;

/// One loaded document, as the viewer pane consumes it. Supplied by `app.d`'s
/// pipeline through the loader delegate, so the workspace never duplicates
/// the read → detect → highlight → parse pipeline.
struct WorkspaceDoc
{
    string title;
    string source;
    HighlightEvent[] events;
    PreviewModel preview;
    TwoslashReturn twoslash; /// empty `code` ⇒ not a twoslash document
    string lang;             /// canonical language (CST fold provider)
}

/// ditto
alias WsLoader = WorkspaceDoc delegate(string path) @system;

/// The workspace: two panes, one frame, one event loop. Global keys (`e`
/// tree toggle, `[`/`]` prev/next file) are handled here; everything else
/// routes to the focused pane, with pointer events translated to pane-local
/// coordinates.
struct WorkspaceTui
{
    ExplorerTui tree;
    PreviewTui viewer;
    bool treeVisible;
    bool treeFocused;
    WsLoader loadDoc;
    private int width, height;
    private RgbColor pageFg, pageBg;
    private size_t lastThemeIdx = size_t.max;

    /// The tree/document split (STM8): `--tree-width` seeds it; dragging
    /// the divider column resizes it live. `size` is the sidebar width in
    /// cells (incl. its own chrome).
    SplitState split = SplitState(32);
    private enum minTreeCols = 12;

    // Pointer capture: the pane that took the press owns every drag until
    // release, so a grab (a scrollbar thumb, a selection) never leaks into
    // the neighbouring pane when the drag crosses the divider.
    private bool pointerDown;
    private bool pointerOnTree;

    // Pointer shape (OSC 22): grab state first — an active divider or
    // scrollbar grab HOLDS its shape until release, wherever the pointer
    // strays — then hover (the divider column → ew-resize, a scrollbar
    // column → ns-resize). The loop drains `takeCursorShape` after each
    // event and writes it out of band — only transitions emit.
    private PointerShape curShape = PointerShape.default_;
    private const(char)[] pendingCursor;

    /// The pointer-shape sequence to write to the terminal, if the hover
    /// state changed since the last take (empty otherwise).
    const(char)[] takeCursorShape() return @safe pure nothrow @nogc
    {
        const s = pendingCursor;
        pendingCursor = null;
        return s;
    }

    /// Recomputes the pane geometry for the current terminal size.
    void arrange(int w, int h) @system
    {
        width = w;
        height = h;
        split = split.clamped(minTreeCols, w / 2 < minTreeCols ? minTreeCols : w / 2);
        const tw = treeVisible ? split.size : 0;
        tree.width = tw;
        tree.height = h;
        // One divider column between the panes.
        viewer.originX = tw > 0 ? tw + 1 : 0;
        viewer.resize(w - viewer.originX, h);
        if (treeVisible)
            tree.rebuild();
        viewer.relayout();
    }

    void paint(ref Grid g) @system
    {
        CellStyle page;
        page.fg = Color.fromRgb(pageFg);
        page.bg = Color.fromRgb(pageBg);
        g.clearTo(page);

        // Focus indication: the focused pane's header renders accented, the
        // other muted; with the tree hidden the viewer is always focused
        // (the standalone look).
        tree.focused = treeFocused;
        viewer.focused = !treeFocused || !treeVisible;

        if (treeVisible)
        {
            tree.paint(g);
            // The divider: a full-height │ rule between the panes, tinted
            // toward the focused side — the tree's accent when the tree
            // holds focus, the muted chrome color otherwise.
            CellStyle div = page;
            div.fg = Color.fromRgb(treeFocused
                ? tree.accent : toRgb(tree.theme.defaults.fg, pageFg));
            foreach (y; 0 .. g.rows)
                g.putText(cast(ushort) tree.width, cast(ushort) y, "│", div);
        }
        viewer.paint(g);
    }

    /// Opens `path` in the viewer pane and reveals it in the tree (XPL3/4).
    private void openDoc(string path) @system
    {
        if (loadDoc is null)
            return;
        WorkspaceDoc doc;
        try
            doc = loadDoc(path);
        catch (Exception)
        {
            return; // the previous document stays on screen
        }
        viewer.setDocument(doc.title, doc.source, doc.events, doc.preview,
            startPreview: true, doc.twoslash, doc.lang);
        tree.reveal(path);
        treeFocused = false;
    }

    // The tree's visible files in row order — the [ / ] navigation space.
    private string[] visibleFiles() @system
    {
        string[] files;
        foreach (ref const r; tree.rows)
            if (!tree.data.nodes[r.node].value.isDir)
                files ~= tree.data.nodes[r.node].value.path;
        return files;
    }

    // `[`/`]`: open the previous/next file of the tree, wrapping (XPL4).
    private void openAdjacent(int step) @system
    {
        auto files = visibleFiles();
        if (!files.length)
            return;
        long at = -1;
        foreach (i, f; files)
            if (f == tree.current)
                at = cast(long) i;
        const n = cast(long) files.length;
        const next = at < 0 ? (step > 0 ? 0 : n - 1) : ((at + step) % n + n) % n;
        openDoc(files[cast(size_t) next]);
    }

    /// The explorer follows the viewer's theme (`XPL5`): when ←/→ cycled it,
    /// re-resolve the tree's page colors + palette and rebuild — the whole
    /// frame re-skins together, not just the document's syntax colors.
    private void syncTreeTheme() @system
    {
        if (viewer.themeIndex == lastThemeIdx || !viewer.themes.length)
            return;
        lastThemeIdx = viewer.themeIndex;
        tree.themeValue = &viewer.themes[viewer.themeIndex];
        tree.theme = resolveTheme(*tree.themeValue, viewer.labels);
        pageFg = tree.pageFg = toRgb(tree.theme.defaults.fg,
            RgbColor(0xcc, 0xcc, 0xcc));
        pageBg = tree.pageBg = toRgb(tree.theme.defaults.bg,
            RgbColor(0x1e, 0x1e, 0x1e));
        tree.rebuild();
    }

    /// Applies one event; returns false to quit.
    bool handle(in Event e) @system
    {
        // Pointer shape (observes only — never consumes). Grabs outrank
        // hover, so the shape holds through the whole drag no matter where
        // the pointer strays; the scrollbars are vertical → ns-resize.
        e.match!((in PointerEvent p) {
            const grabbed = split.dragging || viewer.sb.dragging
                || tree.sb.dragging;
            PointerShape want;
            if (split.dragging)
                want = PointerShape.ewResize;
            else if (viewer.sb.dragging || tree.sb.dragging)
                want = PointerShape.nsResize;
            else if (treeVisible && p.pos.x == tree.width)
                want = PointerShape.ewResize;
            else if ((treeVisible && tree.overScrollbar(p.pos.x, p.pos.y))
                || viewer.overScrollbar(p.pos.x - viewer.originX, p.pos.y))
                want = PointerShape.nsResize;
            else
                want = PointerShape.default_;
            // Re-assert on every event while a grab is live: some terminals
            // and multiplexers reset the pointer themselves when a drag
            // starts, clobbering the OSC 22 shape — a repeated set is
            // idempotent and a few bytes, so keep re-applying it.
            if (want != curShape || (grabbed && p.action == PointerAction.drag))
            {
                curShape = want;
                pendingCursor = "\x1b]22;" ~ cast(string) want ~ "\x1b\\";
            }
        }, (_) {});

        // The wheel scrolls the pane under the CURSOR, not the focused one —
        // both ways: over the tree it scrolls the tree, anywhere else it goes
        // to the viewer (whose wheel arm is position-blind), so a focused
        // tree never swallows a wheel spun over the document.
        {
            bool done;
            e.match!((in WheelEvent wv) {
                if (treeVisible && wv.pos.x < tree.width)
                    tree.scrollBy(3 * wv.dy);
                else
                    viewer.handle(e);
                done = true;
            }, (_) {});
            if (done)
                return true;
        }

        // The divider drag (STM8): a grab on the divider column resizes the
        // tree pane live; the drag owns the pointer until release.
        {
            bool consumed;
            e.match!((in PointerEvent p) {
                if (!treeVisible)
                    return;
                if (split.dragging)
                {
                    split = p.action == PointerAction.release
                        ? split.released()
                        : split.draggedTo(p.pos.x, minTreeCols,
                            width / 2 < minTreeCols ? minTreeCols : width / 2);
                    arrange(width, height);
                    consumed = true;
                }
                else if (p.action == PointerAction.press
                    && p.button == PointerButton.left
                    && p.pos.x == tree.width)
                {
                    split = split.started(p.pos.x);
                    consumed = true;
                }
            }, (_) {});
            if (consumed)
                return true;
        }

        // Global keys — only when no pane is consuming typed text.
        const typing = (treeFocused && tree.inputActive)
            || (!treeFocused && viewer.inputActive);
        if (!typing)
        {
            bool handled;
            bool quit;
            e.match!((in KeyEvent k) {
                if (k.key != Key.char_)
                    return;
                switch (k.ch)
                {
                    case 'e': // toggle the explorer pane; focus follows
                        treeVisible = !treeVisible;
                        treeFocused = treeVisible;
                        arrange(width, height);
                        handled = true;
                        break;
                    // With the tree focused the brackets belong to the pane
                    // (next/prev git change); the viewer keeps them for
                    // document navigation (XPL4).
                    case '[':
                        if (!treeFocused)
                        {
                            openAdjacent(-1);
                            handled = true;
                        }
                        break;
                    case ']':
                        if (!treeFocused)
                        {
                            openAdjacent(+1);
                            handled = true;
                        }
                        break;
                    default: break;
                }
            }, (_) {});
            if (handled)
                return true;
        }

        // Pointer events pick their pane by position on PRESS (click-to-
        // focus) and arrive pane-local; the press captures the pointer, so
        // drags stay with the owning pane across the divider until release.
        // Everything else goes to the focused pane.
        bool toTree = treeFocused;
        Event ev = e;
        e.match!((in PointerEvent p) {
            if (p.action == PointerAction.press || !pointerDown)
            {
                pointerOnTree = treeVisible && p.pos.x < tree.width;
                pointerDown = p.action != PointerAction.release;
                if (p.action == PointerAction.press)
                    treeFocused = pointerOnTree;
            }
            else if (p.action == PointerAction.release)
                pointerDown = false;
            toTree = pointerOnTree;
            if (!toTree && viewer.originX > 0)
            {
                PointerEvent q = p;
                q.pos = Point(p.pos.x - viewer.originX, p.pos.y);
                ev = Event(q);
            }
        }, (_) {});

        if (toTree && treeVisible)
        {
            const alive = tree.handle(ev);
            if (tree.picked.length) // Enter on a file → the viewer pane
            {
                const path = tree.picked;
                tree.picked = null;
                openDoc(path);
                return true;
            }
            if (!alive) // quit intent inside the tree closes the pane
            {
                treeVisible = false;
                treeFocused = false;
                arrange(width, height);
            }
            return true;
        }
        const alive = viewer.handle(ev);
        syncTreeTheme();
        return alive;
    }
}

/**
Runs the workspace until the user quits. `target` is a file (tree hidden,
rooted at its directory, revealed at the file), a directory (tree focused),
or empty (the embedded self-view: `initial` supplies the document). One
terminal session, one loop — the panes swap content, never the screen.
*/
int runWorkspace(string target, bool isDir, WorkspaceDoc initial,
    WsLoader loadDoc,
    const(string)[] names, immutable(Theme)[] themes, size_t themeIdx,
    LabelSet labels, TsConfigCache* cache,
    string[] includeGlobs = null, string[] excludeGlobs = null,
    int treeWidth = 32, int tabWidth = 4, bool listWhitespace = false) @system
{
    WorkspaceTui w;
    w.loadDoc = loadDoc;
    w.split = SplitState(treeWidth < 12 ? 12 : treeWidth);
    w.viewer.tabWidth = tabWidth < 1 ? 1 : tabWidth;
    w.viewer.listWhitespace = listWhitespace;
    w.tree.includeGlobs = includeGlobs;
    w.tree.excludeGlobs = excludeGlobs;

    // The tree pane state (built even while hidden — [ / ] navigate it).
    w.tree.root = isDir ? target : (target.length ? dirName(target) : ".");
    w.tree.themeValue = &themes[themeIdx < themes.length ? themeIdx : 0];
    w.tree.theme = resolveTheme(*w.tree.themeValue, labels);
    w.pageFg = w.tree.pageFg = toRgb(w.tree.theme.defaults.fg,
        RgbColor(0xcc, 0xcc, 0xcc));
    w.pageBg = w.tree.pageBg = toRgb(w.tree.theme.defaults.bg,
        RgbColor(0x1e, 0x1e, 0x1e));

    // The viewer pane session (theme list, shared across documents).
    w.viewer.names = names;
    w.viewer.themes = themes;
    w.viewer.labels = labels;
    w.viewer.cache = cache;
    w.viewer.setTheme(themeIdx);

    w.treeVisible = isDir;
    w.treeFocused = isDir;
    w.lastThemeIdx = themeIdx;
    w.tree.rebuild();
    if (!isDir && initial.title.length)
    {
        // The already-loaded document (no second read); reveal it in the
        // (hidden) tree so `e` opens onto it highlighted.
        w.viewer.setDocument(initial.title, initial.source, initial.events,
            initial.preview, startPreview: true, initial.twoslash,
            initial.lang);
        if (target.length)
            w.tree.reveal(target);
    }
    else if (!isDir && target.length)
        w.openDoc(target);

    // Any-event tracking (1003): bare pointer motion reports too, so the
    // divider can show a hover resize cursor.
    auto term = Terminal.open(TerminalOptions(motion: true));
    if (!term.active)
        return 1;
    scope (exit) term.close();

    auto events = PosixEvents.start();

    Grid g;
    for (;;)
    {
        const sz = term.size();
        if (sz.width != w.width || sz.height != w.height)
            w.arrange(sz.width, sz.height);

        g.resize(sz.width, sz.height);
        w.paint(g);
        term.draw(g);

        const clip = w.viewer.takeClipboard();
        if (clip.length)
            term.writeRaw(clip); // OSC 52 clipboard write (out of band)
        const shape = w.takeCursorShape();
        if (shape.length)
            term.writeRaw(shape); // OSC 22 pointer shape (out of band)

        // While a git-status refresh is in flight, wait in short slices so
        // the finished snapshot paints without requiring a keypress; with
        // none in flight this is the plain blocking read.
        bool gitApplied;
        while (w.tree.git.refreshing && !events.ready(150.msecs))
            if (w.tree.git.poll())
            {
                gitApplied = true;
                break;
            }
        if (gitApplied)
        {
            w.tree.rebuild();
            continue; // repaint with the badges, then wait again
        }
        const ev = events.next();
        if (ev.isEndOfInput)
            break;
        if (ev.match!((in ResizeEvent _) => true, _ => false))
            continue; // next iteration re-measures + re-arranges
        if (!w.handle(ev))
            break;
    }
    return 0;
}

@("workspace.splitPane.composeToggleAndSync")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;

    // tmp/{alpha.d, beta.d} and a stub loader (no grammar registry needed).
    const root = buildPath(tempDir(), "hue-workspace-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, "alpha.d"), "int alpha;\n");
    write(buildPath(root, "beta.d"), "int beta;\n");

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    const labels = LabelSet.standard();

    WorkspaceTui w;
    w.loadDoc = delegate WorkspaceDoc(string path) @system {
        import std.file : readText;
        import std.path : baseName;

        const src = readText(path);
        return WorkspaceDoc(baseName(path), src,
            [HighlightEvent.sourceSpan(0, src.length)], PreviewModel.init);
    };
    w.tree.root = root;
    w.tree.themeValue = &themes[0];
    w.tree.theme = resolveTheme(themes[0], labels);
    w.pageFg = w.tree.pageFg = toRgb(w.tree.theme.defaults.fg,
        RgbColor(0xcc, 0xcc, 0xcc));
    w.pageBg = w.tree.pageBg = toRgb(w.tree.theme.defaults.bg,
        RgbColor(0x1e, 0x1e, 0x1e));
    w.viewer.names = names[];
    w.viewer.themes = themes[];
    w.viewer.labels = labels;
    w.treeVisible = true;
    w.treeFocused = true;
    w.tree.rebuild();
    w.arrange(80, 12);
    w.openDoc(buildPath(root, "alpha.d"));

    Grid g;
    g.resize(80, 12);
    w.paint(g);

    string row(ushort y)
    {
        string s;
        foreach (x; 0 .. g.cols)
            s ~= g[cast(ushort) x, y].grapheme;
        return s;
    }

    // Both panes in one frame: the tree lists both files left of the divider,
    // the viewer header (right of it) names the open one.
    assert(g[cast(ushort) w.tree.width, 3].grapheme == "│", "divider column");
    assert(row(1)[0 .. w.tree.width].canFind("alpha.d"), row(1));
    assert(row(0)[w.viewer.originX .. $].canFind("alpha.d"), row(0));
    assert(row(1)[w.viewer.originX .. $].canFind("int alpha;"), row(1));

    // XPL3: the open file's label carries the theme accent, the other not.
    bool alphaAccented;
    foreach (ref const n; w.tree.data.nodes)
        if (n.value.name == "alpha.d")
            alphaAccented = n.value.hasLabelFg && n.value.labelFg == w.tree.accent;
    assert(alphaAccented, "the open document is highlighted in the tree");

    // With the tree focused, ']' belongs to the pane (git-change jump) —
    // the document must NOT switch (XPF1's focus-dependent brackets).
    w.treeFocused = true; // (openDoc hands focus to the viewer)
    const before = w.tree.current;
    assert(w.handle(Event(KeyEvent(key: Key.char_, ch: ']'))));
    assert(w.tree.current == before, "tree-focused ']' switches no document");

    // XPL4: ']' (viewer-focused) opens the next file and the tree follows.
    w.treeFocused = false;
    assert(w.handle(Event(KeyEvent(key: Key.char_, ch: ']'))));
    assert(w.tree.current.canFind("beta.d"));
    w.paint(g);
    assert(row(0)[w.viewer.originX .. $].canFind("beta.d"), row(0));

    // 'e' hides the tree: the viewer takes the full width.
    assert(w.handle(Event(KeyEvent(key: Key.char_, ch: 'e'))));
    assert(!w.treeVisible && w.viewer.originX == 0);
    w.paint(g);
    assert(row(1).canFind("int beta;"), row(1));
}

@("workspace.splitDivider.dragResizesTheTree")
@system
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;

    const root = buildPath(tempDir(), "hue-workspace-split-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, "a.d"), "int a;\n");

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    WorkspaceTui w;
    w.tree.root = root;
    w.tree.themeValue = &themes[0];
    w.tree.theme = resolveTheme(themes[0], LabelSet.standard());
    w.viewer.names = names[];
    w.viewer.themes = themes[];
    w.viewer.labels = LabelSet.standard();
    w.treeVisible = true;
    w.tree.rebuild();
    w.arrange(100, 12);
    assert(w.tree.width == 32, "the default split");

    // Grab the divider column, drag right by 6, release (STM8).
    const div = w.tree.width;
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(div, 4)))));
    assert(w.split.dragging);
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(div + 6, 4)))));
    assert(w.tree.width == 38, "the pane followed the drag");
    assert(w.viewer.originX == 39, "the viewer moved with the divider");
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(div + 6, 4)))));
    assert(!w.split.dragging && w.tree.width == 38);

    // The drag clamps: far left pins at the minimum, far right at half.
    w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(38, 4))));
    w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(0, 4))));
    assert(w.tree.width == 12, "clamped at the minimum");
    w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(99, 4))));
    assert(w.tree.width == 50, "clamped at half the screen");
    w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(99, 4))));
}

@("workspace.pointerCapture.grabsStayWithTheirPane")
@system
unittest
{
    import std.conv : text;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;

    // Enough files that the tree overflows its pane (its scrollbar is live)
    // and a long document in the viewer.
    const root = buildPath(tempDir(), "hue-workspace-capture-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    foreach (i; 0 .. 20)
        write(buildPath(root, text("f", i, ".d")), "int x;\n");
    string src;
    foreach (i; 0 .. 40)
        src ~= "int line;\n";
    write(buildPath(root, "long.d"), src);

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    WorkspaceTui w;
    w.loadDoc = delegate WorkspaceDoc(string path) @system {
        import std.file : readText;
        import std.path : baseName;

        const s = readText(path);
        return WorkspaceDoc(baseName(path), s,
            [HighlightEvent.sourceSpan(0, s.length)], PreviewModel.init);
    };
    w.tree.root = root;
    w.tree.themeValue = &themes[0];
    w.tree.theme = resolveTheme(themes[0], LabelSet.standard());
    w.viewer.names = names[];
    w.viewer.themes = themes[];
    w.viewer.labels = LabelSet.standard();
    w.treeVisible = true;
    w.tree.rebuild();
    w.arrange(100, 12);
    w.openDoc(buildPath(root, "long.d"));
    assert(cast(long) w.tree.rows.length > w.tree.bodyRows);

    // A grab on the tree's scrollbar stays with the tree when the drag
    // crosses the divider into the document pane — no text selection.
    const sbCol = w.tree.width - 1;
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(sbCol, 2)))));
    assert(w.tree.sb.dragging);
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(60, 6)))));
    assert(w.tree.sb.dragging, "the tree kept the grab across the divider");
    assert(!w.viewer.selection.active, "no text selection from a tree-owned drag");
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(60, 6)))));
    assert(!w.tree.sb.dragging);

    // Symmetrically: a selection started in the document keeps extending
    // when the drag crosses into the tree pane — and never steals focus.
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(60, 2)))));
    assert(w.viewer.selection.active);
    assert(!w.treeFocused, "the press focused the viewer");
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(5, 5)))));
    assert(w.viewer.selection.active && w.viewer.selection.lo != w.viewer.selection.hi,
        "the selection extended across the divider");
    assert(!w.treeFocused, "a drag never steals focus");
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(5, 5)))));
}

@("workspace.chrome.hoverCursorAndFocusIndication")
@system
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;

    const root = buildPath(tempDir(), "hue-workspace-chrome-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    string src;
    foreach (i; 0 .. 40)
        src ~= "int line;\n";
    write(buildPath(root, "long.d"), src);

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    WorkspaceTui w;
    w.loadDoc = delegate WorkspaceDoc(string path) @system {
        import std.file : readText;
        import std.path : baseName;

        const s = readText(path);
        return WorkspaceDoc(baseName(path), s,
            [HighlightEvent.sourceSpan(0, s.length)], PreviewModel.init);
    };
    w.tree.root = root;
    w.tree.themeValue = &themes[0];
    w.tree.theme = resolveTheme(themes[0], LabelSet.standard());
    w.viewer.names = names[];
    w.viewer.themes = themes[];
    w.viewer.labels = LabelSet.standard();
    w.treeVisible = true;
    w.treeFocused = true;
    w.tree.rebuild();
    w.arrange(100, 12);
    w.openDoc(buildPath(root, "long.d"));

    // OSC 22 divider hover: entering emits ew-resize, leaving restores the
    // default, and no-transition motion emits nothing.
    const div = w.tree.width;
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(div, 4)))));
    assert(w.takeCursorShape() == "\x1b]22;ew-resize\x1b\\");
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(div, 6)))));
    assert(w.takeCursorShape().length == 0, "no transition, no write");
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(60, 6)))));
    assert(w.takeCursorShape() == "\x1b]22;default\x1b\\");

    // The viewer's scrollbar column hovers as ns-resize (vertical), and a
    // grab HOLDS the shape wherever the drag strays — no revert mid-drag.
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(99, 4)))));
    assert(w.takeCursorShape() == "\x1b]22;ns-resize\x1b\\");
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(99, 4)))));
    assert(w.viewer.sb.dragging);
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(60, 6)))));
    // Mid-grab drags RE-ASSERT the held shape (never default): terminals /
    // multiplexers may reset the pointer on drag start, so the idempotent
    // re-set keeps the resize shape pinned.
    assert(w.takeCursorShape() == "\x1b]22;ns-resize\x1b\\",
        "the grab re-asserts its shape through the stray drag");
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(60, 6)))));
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(60, 6)))));
    assert(w.takeCursorShape() == "\x1b]22;default\x1b\\");

    // Focus indication: paint stamps the focused pane; the hidden-tree
    // viewer is always focused (the standalone look).
    w.treeFocused = true; // (openDoc handed focus to the viewer)
    Grid g;
    g.resize(100, 12);
    w.paint(g);
    assert(w.tree.focused && !w.viewer.focused);
    // The focused pane's header title is BOLD on the accent band; the
    // unfocused pane's is not (the at-a-glance indicator).
    import sparkles.base.term_style : TextAttr;
    assert(g[1, 0].style.attrs.has(TextAttr.bold),
        "the focused tree title renders bold");
    assert(!g[cast(ushort)(w.viewer.originX + 1), 0].style.attrs
        .has(TextAttr.bold), "the unfocused viewer title stays regular");
    w.treeFocused = false;
    w.paint(g);
    assert(!w.tree.focused && w.viewer.focused);
    w.treeVisible = false;
    w.treeFocused = true; // stale focus flag must not defeat the fallback
    w.arrange(100, 12);
    w.paint(g);
    assert(w.viewer.focused, "a lone viewer is always focused");
}

@("workspace.wheel.scrollsThePaneUnderTheCursor")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;

    const root = buildPath(tempDir(), "hue-workspace-wheel-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    string src;
    foreach (i; 0 .. 30)
        src ~= "int line" ~ cast(char)('0' + i / 10) ~ cast(char)('0' + i % 10)
            ~ ";\n";
    write(buildPath(root, "long.d"), src);

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    WorkspaceTui w;
    w.loadDoc = delegate WorkspaceDoc(string path) @system {
        import std.file : readText;
        import std.path : baseName;

        const s = readText(path);
        return WorkspaceDoc(baseName(path), s,
            [HighlightEvent.sourceSpan(0, s.length)], PreviewModel.init);
    };
    w.tree.root = root;
    w.tree.themeValue = &themes[0];
    w.tree.theme = resolveTheme(themes[0], LabelSet.standard());
    w.viewer.names = names[];
    w.viewer.themes = themes[];
    w.viewer.labels = LabelSet.standard();
    w.treeVisible = true;
    w.tree.rebuild();
    w.arrange(100, 12);
    w.openDoc(buildPath(root, "long.d"));

    // The failing configuration: the TREE holds focus while the wheel spins
    // over the DOCUMENT pane — the wheel must scroll the pane under the
    // cursor, not be swallowed by the focused tree.
    w.treeFocused = true;
    Grid g;
    g.resize(100, 12);
    w.paint(g);
    string row(ushort y)
    {
        string s;
        foreach (x; 0 .. g.cols)
            s ~= g[cast(ushort) x, y].grapheme;
        return s;
    }
    assert(row(1)[w.viewer.originX .. $].canFind("int line00;"), row(1));

    assert(w.handle(Event(WheelEvent(dy: 1, pos: Point(60, 5)))));
    w.paint(g);
    assert(row(1)[w.viewer.originX .. $].canFind("int line03;"),
        "wheel over the document scrolled it despite tree focus: " ~ row(1));
    assert(w.treeFocused, "the wheel does not steal focus");

    // And back up.
    assert(w.handle(Event(WheelEvent(dy: -1, pos: Point(60, 5)))));
    w.paint(g);
    assert(row(1)[w.viewer.originX .. $].canFind("int line00;"), row(1));
}
