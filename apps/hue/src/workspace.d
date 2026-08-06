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
import sparkles.ui_tui : CellStyle, Color, Grid;
import sparkles.ui_tui.session : TerminalRequest, TerminalSession;
import sparkles.input : EndOfInput, Event, isEndOfInput, Key, KeyEvent,
    linesPerNotch, match, PointerAction, PointerButton, PointerEvent,
    ResizeEvent, WheelEvent;
import sparkles.ui.dock : DockAxis, DockContainer, PaneId, RouteKind;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.style : Slot;

import ansi_model : BackgroundMode;
import document : Document;
import explorer : ExplorerTui;
import gui_preview : PreviewModel;
import live_types : applyTip, LiveTypesSession;
import sparkles.twoslash.protocol : TwoslashReturn;
import tui : PreviewTui;

/// One loaded document, as the viewer pane consumes it — the pipeline's
/// `Document` Whole itself, so the transport loses nothing at the pane
/// boundary (the content kind and the diff payload ride along; the pane
/// used to re-infer preview-vs-twoslash from payload presence because this
/// boundary dropped the kind).
alias WorkspaceDoc = Document;

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
    WsLoader loadDoc;
    /// Live D types (`PRJ12`-`PRJ16`): a `twoslash-extract --dub --serve`
    /// oracle for the open `.d` document. The session belongs to the document
    /// — opening another file ends it — and its stderr is silenced, because
    /// this pane is an alt screen a stray `dub describe` line would corrupt.
    bool liveTypes = true;
    private LiveTypesSession* live;
    private string liveNotice; // shown once, after the terminal is restored
    private int width, height;
    private RgbColor pageFg, pageBg;
    private size_t lastThemeIdx = size_t.max;

    /**
    The pane composition (`C-2a`): the toolkit's dock container owns the
    arrangement (a fixed-width sidebar left of the flexing document), the
    STM8 divider drag, the STM11 capture, focus, wheel routing and the
    coordinate translation. What is left here is what is genuinely hue's:
    which panes exist, what its keys mean, and how a pane paints.
    */
    DockContainer dock;
    private enum PaneId treePane = 1, docPane = 2;
    private enum minTreeCols = 12;

    /// The sidebar's width in cells (incl. its own chrome) — `--tree-width`
    /// seeds it, the divider drag moves it.
    int treeCols() const @safe pure nothrow
        => dock.layout.nodes[dock.layout.nodeOf(treePane)].extent;

    /// ditto
    void treeCols(int cols) @safe pure nothrow
    {
        dock.layout.nodes[dock.layout.nodeOf(treePane)].extent = cols;
    }

    /// Whether the explorer pane is shown at all ('e' toggles it).
    bool treeVisible() const @safe pure nothrow
        => dock.layout.visible(treePane);

    /// ditto
    void treeVisible(bool v) @safe pure nothrow
    {
        dock.layout.setVisible(treePane, v);
    }

    /// Whether the explorer pane holds focus (`DCK6`, container-owned).
    bool treeFocused() const @safe pure nothrow @nogc
        => dock.focused == treePane;

    /// ditto
    void treeFocused(bool v) @safe pure nothrow @nogc
    {
        dock.focused = v ? treePane : docPane;
    }

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

    /// Builds the two-pane arrangement — called once, before `arrange`.
    private void buildLayout(int treeWidth) @safe
    {
        if (dock.layout.nodes.length)
            return;
        const t = dock.layout.addLeaf(treePane,
            extent: treeWidth < minTreeCols ? minTreeCols : treeWidth,
            minExtent: minTreeCols);
        const d = dock.layout.addLeaf(docPane);
        dock.layout.root = dock.layout.addSplit(DockAxis.horizontal, [t, d]);
        dock.focused = docPane;
    }

    /// Recomputes the pane geometry for the current terminal size: the
    /// container tiles the area, the panes are told the rects it produced.
    void arrange(int w, int h) @system
    {
        width = w;
        height = h;
        buildLayout(32);
        // The sidebar never takes more than half the terminal; the
        // container re-clamps the extent against this on every arrange.
        dock.layout.nodes[dock.layout.nodeOf(treePane)].maxExtent =
            w / 2 < minTreeCols ? minTreeCols : w / 2;
        dock.arrange(Rect(0, 0, w, h));

        foreach (ref f; dock.paneFrames)
            if (f.pane == treePane)
            {
                tree.width = f.rect.width;
                tree.height = f.rect.height;
            }
            else
            {
                viewer.originX = f.rect.x;
                viewer.resize(f.rect.width, f.rect.height);
            }
        if (!treeVisible)
            tree.width = 0; // the paint/hit helpers read this as "no pane"
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
            // The dividers the container placed: a full-height │ rule,
            // tinted toward the focused side — the tree's accent when the
            // tree holds focus, the muted chrome color otherwise.
            CellStyle div = page;
            div.fg = Color.fromRgb(treeFocused
                ? tree.accent : toRgb(tree.theme.defaults.fg, pageFg));
            foreach (ref d; dock.dividers)
                foreach (y; d.rect.y .. d.rect.y + d.rect.height)
                    g.putText(cast(ushort) d.rect.x, cast(ushort) y, "│", div);
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
            startPreview: true, doc.twoslash, doc.lang, doc.diffDoc,
            doc.diffSides, doc.diffSession);
        syncTreeSession();
        tree.reveal(path);
        treeFocused = false;
        startLive(path, doc.twoslash.code.length != 0);
    }

    // ── Live D types ────────────────────────────────────────────────────────

    /// Starts the oracle for a freshly opened `.d` document (`PRJ12`: on open,
    /// off the render path). A document that already carries a payload — a
    /// `*.twoslash.json` target — needs none.
    package void startLive(string path, bool alreadyHasPayload) @system
    {
        import std.algorithm.searching : endsWith;

        stopLive();
        if (!liveTypes || alreadyHasPayload || !path.endsWith(".d"))
            return;
        string reason;
        // The child's stderr goes to /dev/null: the analyzer's warnings and
        // dub's own chatter would otherwise land on the alt screen.
        live = LiveTypesSession.start(path, reason, silenceChildStderr: true);
        if (live is null && !liveNotice.length)
            liveNotice = reason;
    }

    /// ditto
    package void stopLive() @system
    {
        if (live is null)
            return;
        live.shutdown();
        live = null;
    }

    /// The loop ticks on a deadline (rather than blocking on input) exactly
    /// while this holds.
    package bool liveActive() const @safe pure nothrow @nogc
        => live !is null;

    /// One tick of the oracle: attach the payload when it lands, write
    /// answered tips into their nodes, and resolve the open popup's node.
    /// Non-blocking — nothing here waits on the analysis. Returns `true` when
    /// the frame changed, so an idle tick costs a `poll` and a `read`, not a
    /// repaint (the wire stays silent between keystrokes, as it always was).
    package bool pollLive() @system
    {
        if (live is null)
            return false;
        bool changed;
        live.poll();
        if (live.payloadReady)
        {
            viewer.attachTwoslash(live.takePayload());
            changed = true;
        }
        foreach (a; live.takeAnswers())
            changed |= applyTip(viewer.twoslashPayload, a);

        // The popup the user opened is the request: `p`-cycling or clicking a
        // lazy span asks for that node once (the session dedupes).
        const sel = viewer.selectedHoverNode;
        if (sel >= 0 && !viewer.twoslashPayload.nodes[cast(size_t) sel].text.length)
            live.requestTip(cast(size_t) sel);

        if (live.failed)
        {
            if (!liveNotice.length)
                liveNotice = live.reason;
            stopLive();
        }
        return changed;
    }

    /// The one-line live-types notice (no binary, or a child that died), taken
    /// once — the caller prints it after the terminal is restored, never into
    /// the alt screen (`PRJ15`).
    package string takeLiveNotice() @safe pure nothrow @nogc
    {
        const n = liveNotice;
        liveNotice = null;
        return n;
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
    /// `DVG1`: the viewer is showing a multi-file diff, so the bracket keys
    /// belong to its changed-file list rather than to the tree's neighbours.
    private bool viewerHasDiffSession() const @safe pure nothrow @nogc
        => viewer.diffNav();

    /// `TVU6`: point the explorer at the open document's changed-file session
    /// (or back at the filesystem when it is not a diff). Called wherever the
    /// viewer's document changes, so the two panes never disagree about what
    /// is being shown.
    package void syncTreeSession() @system
    {
        tree.session = viewer.diffEntries();
        tree.rebuild();
    }

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

    // The shape a live PANE grab wants (empty when none is grabbing) and
    // the one a mere hover wants — apart, because the container's
    // precedence (DCK9) puts every grab above every hover.
    private PointerShape paneGrabShape() @safe pure nothrow @nogc
    {
        if (viewer.vm.scroll.grabbing)
            return viewer.vm.scroll.shape();
        if (tree.scroll.grabbing)
            return tree.scroll.shape();
        return PointerShape.default_;
    }

    /// ditto
    private PointerShape paneHoverShape() @safe pure nothrow @nogc
    {
        const v = viewer.vm.scroll.shape();
        return v != PointerShape.default_ ? v : tree.scroll.shape();
    }

    /// Applies one event; returns false to quit.
    bool handle(in Event e) @system
    {
        // Pointer shape (observes only — never consumes). The panes hover
        // their own bars from pane-local positions; the container composes
        // those with its dividers into the one wanted shape.
        e.match!((in PointerEvent p) {
            // The shape is written out of band, BEFORE the event routes, so
            // the container's hover is refreshed here rather than waited on.
            dock.hovered(p.pos);
            const vx = p.pos.x - viewer.originX;
            viewer.sb = viewer.sb.hoveredNow(
                viewer.overScrollbar(vx, p.pos.y));
            viewer.vm.hsb = viewer.vm.hsb.hoveredNow(
                viewer.overHScrollbar(vx, p.pos.y));
            tree.sb = tree.sb.hoveredNow(
                treeVisible && tree.overScrollbar(p.pos.x, p.pos.y));
            tree.hsb = tree.hsb.hoveredNow(
                treeVisible && tree.overHScrollbar(p.pos.x, p.pos.y));
            const grabbed = dock.resizing
                || paneGrabShape() != PointerShape.default_;
            const want = dock.shape(paneGrabShape(), paneHoverShape());
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
                    // …and a diff session claims them ahead of the document
                    // set: the changed-file list is what is being walked
                    // (`DVG1`).
                    case '[':
                        if (!treeFocused)
                        {
                            if (viewerHasDiffSession)
                                viewer.moveDiffFile(-1);
                            else
                                openAdjacent(-1);
                            handled = true;
                        }
                        break;
                    case ']':
                        if (!treeFocused)
                        {
                            if (viewerHasDiffSession)
                                viewer.moveDiffFile(+1);
                            else
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

        // Everything positional — and the keys the panes own — is routed by
        // the container (DCK13): capture first, then dividers, then the
        // pane under the pointer, with coordinates already pane-local.
        const r = dock.handle(e);
        if (r.kind == RouteKind.container)
        {
            // A divider drag: the container resized the layout, the panes
            // are told their new rects.
            if (r.relayout)
                arrange(width, height);
            return true;
        }
        if (r.kind == RouteKind.none)
            return true;
        const toTree = r.pane == treePane;
        const ev = r.event;

        if (toTree && treeVisible)
        {
            const alive = tree.handle(ev);
            if (tree.pickedSession >= 0) // `TVU6`: a changed-file row
            {
                const idx = cast(size_t) tree.pickedSession;
                tree.picked = null;
                tree.pickedSession = -1;
                // The file is already in the open diff — jump, do not reload.
                viewer.selectDiffFile(idx);
                treeFocused = false;
                return true;
            }
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
    int treeWidth = 32, int tabWidth = 4, bool listWhitespace = false,
    bool liveTypes = true) @system
{
    WorkspaceTui w;
    w.loadDoc = loadDoc;
    w.liveTypes = liveTypes;
    w.buildLayout(treeWidth);
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
            initial.lang, initial.diffDoc, initial.diffSides,
            initial.diffSession);
        w.syncTreeSession();
        if (target.length)
            w.tree.reveal(target);
        if (target.length)
            w.startLive(target, initial.twoslash.code.length != 0);
    }
    else if (!isDir && target.length)
        w.openDoc(target);

    // The terminal session is a block of its own: the live-types notice must
    // reach a restored screen, never the alt screen (`PRJ15`).
    {
        // Any-event tracking (1003): bare pointer motion reports too, so the
        // divider can show a hover resize cursor.
        // The session owns raw-mode entry and restore, the surface and the
        // input reader (UIA8) — hue names no `sparkles:tui` type for any of
        // it. The grid is still handed out, because hue paints some chrome by
        // hand; folding it in is the same change as widget-ising that chrome.
        auto term = TerminalSession.open(TerminalRequest(motion: true));
        if (!term.active)
            return 1;
        scope (exit) w.stopLive();
        // Every event repaints; a live tick only does when it changed the
        // document, so an idle session emits nothing to the terminal.
        bool dirty = true;
        for (;;)
        {
            // Live types tick before the frame, so an arriving payload or tip
            // paints in the same pass.
            dirty |= w.pollLive();

            if (dirty)
            {
                const sz = term.resizeToTerminal();
                if (sz.width != w.width || sz.height != w.height)
                    w.arrange(sz.width, sz.height);

                w.paint(term.grid);
                term.present();
                dirty = false;
            }

            const clip = w.viewer.takeClipboard();
            if (clip.length)
                term.writeOutOfBand(clip); // OSC 52 clipboard (out of band)
            const shape = w.takeCursorShape();
            if (shape.length)
                term.writeOutOfBand(shape); // OSC 22 pointer shape

            // While a git-status refresh is in flight, wait in short slices so
            // the finished snapshot paints without requiring a keypress.
            bool gitApplied;
            while (w.tree.git.refreshing && !term.ready(150))
                if (w.tree.git.poll())
                {
                    gitApplied = true;
                    break;
                }
            if (gitApplied)
            {
                w.tree.rebuild();
                dirty = true;
                continue; // repaint with the badges, then wait again
            }

            // With an oracle running the loop wakes on a deadline as well as
            // on input, so the analysis lands without a keystroke; with none it
            // blocks exactly as it always has (no idle wakeups).
            const ev = w.liveActive
                ? term.next(cast(int) liveTick.total!"msecs") : term.next();
            if (ev.isEndOfInput)
                break;
            if (ev == Event.init)
                continue; // the live tick expired (or an unrecognized sequence)
            dirty = true;
            if (ev.match!((in ResizeEvent _) => true, _ => false))
                continue; // next iteration re-measures + re-arranges
            if (!w.handle(ev))
                break;
        }
    }

    const notice = w.takeLiveNotice();
    if (notice.length)
    {
        import std.stdio : stderr;

        stderr.writeln("hue: live D types unavailable: ", notice);
    }
    return 0;
}

/// How long the loop waits for input before ticking the live oracle again
/// (~30 Hz — imperceptible for a ~0.6 ms tip answer, idle when no session).
private enum liveTick = 33.msecs;

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
        return WorkspaceDoc(title: baseName(path), source: src,
            events: [HighlightEvent.sourceSpan(0, src.length)]);
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
    assert(w.dock.resizing);
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(div + 6, 4)))));
    assert(w.tree.width == 38, "the pane followed the drag");
    assert(w.viewer.originX == 39, "the viewer moved with the divider");
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(div + 6, 4)))));
    assert(!w.dock.resizing && w.tree.width == 38);

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
        return WorkspaceDoc(title: baseName(path), source: s,
            events: [HighlightEvent.sourceSpan(0, s.length)]);
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
        return WorkspaceDoc(title: baseName(path), source: s,
            events: [HighlightEvent.sourceSpan(0, s.length)]);
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
        return WorkspaceDoc(title: baseName(path), source: s,
            events: [HighlightEvent.sourceSpan(0, s.length)]);
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

    // `dy` is CELLS, not notches (INP12) — an injected event carries what the
    // producer would have emitted, so one notch is `linesPerNotch` rows.
    assert(w.handle(Event(WheelEvent(dy: linesPerNotch, pos: Point(60, 5)))));
    w.paint(g);
    assert(row(1)[w.viewer.originX .. $].canFind("int line03;"),
        "wheel over the document scrolled it despite tree focus: " ~ row(1));
    assert(w.treeFocused, "the wheel does not steal focus");

    // And back up.
    assert(w.handle(Event(WheelEvent(dy: -linesPerNotch, pos: Point(60, 5)))));
    w.paint(g);
    assert(row(1)[w.viewer.originX .. $].canFind("int line00;"), row(1));
}

@("workspace.liveTypes.payloadAttachesAndTipResolves")
@system
unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import std.algorithm.searching : canFind;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    import sparkles.core_cli.process_utils : isInPath;
    import sparkles.syntax : builtinDark, LabelSet;
    import sparkles.test_runner.skip : skipTest;
    import live_types : LiveTypesSession;

    if (!isInPath("sh"))
        skipTest("no `sh` for the scripted oracle");

    // The TUI half of `PRJ12`-`PRJ14`, end to end without a terminal: a
    // scripted oracle stands in for `twoslash-extract --serve` (same wire
    // contract), so this exercises the loop's tick — payload attaches, the
    // opened popup requests its node, the answer paints — with no DMD, no
    // pty, and no timing on a real analysis.
    const root = buildPath(tempDir(), "hue-live-types-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    const src = "int alpha;\n";
    const path = buildPath(root, "alpha.d");
    write(path, src);

    enum payload = `{"code":"int alpha;\n","offsetEncoding":"utf-8",` ~
        `"language":"d","nodes":[{"type":"hover","start":4,"length":5,` ~
        `"line":0,"character":4}]}`;
    enum script = `printf '%s\n' '` ~ payload ~ `'; ` ~
        `while IFS= read -r line; do ` ~
        `printf '%s\n' '{"node":0,"text":"(variable) int alpha",` ~
        `"docs":"","tags":[]}'; done`;

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    const labels = LabelSet.standard();

    WorkspaceTui w;
    w.loadDoc = delegate WorkspaceDoc(string p) @system {
        import std.file : readText;
        import std.path : baseName;

        const s = readText(p);
        return WorkspaceDoc(title: baseName(p), source: s,
            events: [HighlightEvent.sourceSpan(0, s.length)]);
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
    w.tree.rebuild();
    w.arrange(60, 14);
    w.openDoc(path);

    // The session the loop would have started (`startLive` spawns the real
    // binary; the test injects the scripted stand-in instead).
    string reason;
    w.live = LiveTypesSession.startWith(["sh", "-c", script], reason);
    assert(w.live !is null, reason);
    scope (exit) w.stopLive();
    assert(w.liveActive, "the loop ticks while a session is alive");

    bool tick(scope bool delegate() @system done)
    {
        foreach (_; 0 .. 400)
        {
            w.pollLive();
            if (done())
                return true;
            Thread.sleep(5.msecs);
        }
        return false;
    }

    // The payload attaches to the document already on screen: same source,
    // now with the hover span the underline decoration rides on.
    assert(tick(() => w.viewer.twoslashPayload.nodes.length != 0),
        "no payload attached");
    assert(w.viewer.twoslashPayload.code == src);
    assert(!w.viewer.twoslashPayload.nodes[0].text.length, "the span is lazy");

    Grid g;
    g.resize(60, 14);
    w.paint(g);
    string row(ushort y)
    {
        string s;
        foreach (x; 0 .. g.cols)
            s ~= g[cast(ushort) x, y].grapheme;
        return s;
    }
    assert(row(1).canFind("int alpha;"), row(1));

    // How many rows show the type text — the code line itself, plus the popup
    // once it has content. A lazy span must add none.
    int rowsWith(string needle)
    {
        int n;
        foreach (y; 0 .. g.rows)
            if (row(cast(ushort) y).canFind(needle))
                ++n;
        return n;
    }

    // Opening the popup ('p') is the request; until the answer lands the popup
    // has nothing to show (the underline is the only affordance).
    assert(w.handle(Event(KeyEvent(key: Key.char_, ch: 'p'))));
    assert(w.viewer.selectedHoverNode == 0);
    w.paint(g);
    assert(rowsWith("int alpha") == 1, "a lazy popup paints nothing");

    // The tick sends the request and writes the answer into the node in
    // place; the popup then paints the resolved type.
    assert(tick(() => w.viewer.twoslashPayload.nodes[0].text.length != 0),
        "no tip answer");
    w.paint(g);
    assert(rowsWith("int alpha") == 2,
        "the resolved type composites over the pane");
}
