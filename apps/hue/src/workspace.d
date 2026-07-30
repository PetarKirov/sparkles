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

import sparkles.syntax : HighlightEvent, LabelSet, resolveTheme, RgbColor,
    Theme, toRgb;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.tui : CellStyle, Color, Grid, PosixEvents, Terminal;
import sparkles.tui.input : EndOfInput, Event, isEndOfInput, Key, KeyEvent,
    match, PointerEvent, ResizeEvent, WheelEvent;
import sparkles.ui.geometry : Point;
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

    private enum treeCols = 32; // sidebar width incl. its own chrome

    /// Recomputes the pane geometry for the current terminal size.
    void arrange(int w, int h) @system
    {
        width = w;
        height = h;
        const tw = treeVisible ? (w / 2 < treeCols ? w / 2 : treeCols) : 0;
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

        if (treeVisible)
        {
            tree.paint(g);
            // The divider: a full-height │ rule between the panes, tinted
            // toward the focused side's chrome.
            CellStyle div = page;
            div.fg = Color.fromRgb(toRgb(tree.theme.defaults.fg, pageFg));
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
            startPreview: true, doc.twoslash);
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
        // The wheel scrolls the pane under the CURSOR, not the focused one.
        {
            bool done;
            e.match!((in WheelEvent wv) {
                if (treeVisible && wv.pos.x < tree.width)
                {
                    tree.scrollBy(3 * wv.dy);
                    done = true;
                }
            }, (_) {});
            if (done)
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
                    case '[': openAdjacent(-1); handled = true; break;
                    case ']': openAdjacent(+1); handled = true; break;
                    default: break;
                }
            }, (_) {});
            if (handled)
                return true;
        }

        // Pointer events pick their pane by position (click-to-focus) and
        // arrive pane-local; everything else goes to the focused pane.
        bool toTree = treeFocused;
        Event ev = e;
        e.match!((in PointerEvent p) {
            toTree = treeVisible && p.pos.x < tree.width;
            if (!toTree && viewer.originX > 0)
            {
                PointerEvent q = p;
                q.pos = Point(p.pos.x - viewer.originX, p.pos.y);
                ev = Event(q);
            }
            treeFocused = toTree;
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
    LabelSet labels, TsConfigCache* cache) @system
{
    WorkspaceTui w;
    w.loadDoc = loadDoc;

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
            initial.preview, startPreview: true, initial.twoslash);
        if (target.length)
            w.tree.reveal(target);
    }
    else if (!isDir && target.length)
        w.openDoc(target);

    auto term = Terminal.open();
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

    // XPL4: ']' opens the next file and the tree follows.
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
