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

import core.time : Duration;
import core.time : msecs;
import std.path : dirName;
import format_preview : formatPreviewPump, formatPreviewRulerDragging,
    formatPreviewStart;

import sparkles.base.term_control : PointerShape;
import sparkles.base.unique : makeUnique;
import sparkles.syntax.md.render_widgets : OverflowPolicy;
import sparkles.syntax : HighlightEvent, LabelSet, resolveTheme, RgbColor,
    Theme, toRgb;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.ui_tui : CellStyle, Color, Grid;
import sparkles.ui_app.backend : Backend, BackendPolicy;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.run : run, RunOutcome;
import sparkles.input : EndOfInput, Event, isEndOfInput, isNoEvent, Key,
    KeyEvent, linesPerNotch, match, mousePointer, NoEvent, PointerAction,
    PointerButton, PointerEvent, ResizeEvent, WheelEvent;
import sparkles.ui.components.dock : DockAxis, DockContainer, PaneId, RouteKind;
import sparkles.ui.layout : Frame;
import sparkles.ui.widget : WidgetTree;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.style : Slot;

import ansi_model : BackgroundMode;
import diff_view : DiffLayout;
import document : Document;
import dsv_browser : DsvBrowser, fuzzyRowMask;
import dsv_view : adaptDsv, DsvCopy, dsvStatusNote, flagsOf, resolveTableCopy;
import explorer : ExplorerTui;
import inspector_pane : InspectorPane;

import picker_host : OwnedPicker, PickerAction, PickerHost;
import picker_preview : PickerDocPane;
import picker_view : PickerGeometry;
import gui_preview : PreviewModel;
import live_types : applyTip, LiveTypesSession;
import sparkles.twoslash.protocol : TwoslashReturn;
import tui : PreviewTui;
import viewer_model : ScrollAnchorMode;

version (linux)
    import sparkles.event_horizon.watch : Watcher;

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
    string tableCopyFlag = "auto"; /// `--table-copy` raw flag (`DSC2`)
    DsvBrowser dsvBrowser; /// the data browser's projection state (`DSB1`)
    /// Live D types (`PRJ12`-`PRJ16`): a `twoslash-extract --dub --serve`
    /// oracle for the open `.d` document. The session belongs to the document
    /// — opening another file ends it — and its stderr is silenced, because
    /// this pane is an alt screen a stray `dub describe` line would corrupt.
    bool liveTypes = true;
    private LiveTypesSession* live;
    /// `DVT1`: the two oracles a diff needs — one per side of the focused
    /// file. A diff's sides are two different texts, so one session cannot
    /// answer for both; everything else about them is the `live` machinery.
    private LiveTypesSession*[2] diffLive;
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
    private enum PaneId treePane = 1, docPane = 2, inspPane = 3;
    private enum minTreeCols = 12;

    /// The tree-sitter inspector pane (`TSI`/`INS6`), right of the document.
    InspectorPane insp;

    /// The fuzzy file picker (`<leader>ff`, `PKS1`) — heap so the workspace
    /// stays copy-friendly for tests; allocated on first open (a user
    /// action, under `NFR1`'s startup carve-out). `runWorkspace` shuts its
    /// worker pool down on exit.
    package OwnedPicker picker;
    /// The picker's preview: another document pane, fed by the same loader
    /// and theme as the main viewer (`picker_preview`). Heap with `picker`.
    package PickerDocPane* pickerDoc;

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
    private PointerShape pendingShape;
    private bool shapePending;

    /**
    The shape the pointer should take, if the hover state changed since the
    last take.

    The $(B shape), not the escape sequence that spells it: OSC 22 is how a
    terminal is told, and the host owns that — a window sets a cursor through
    the window system instead, and an application that hand-rolled the
    sequence could only ever address one of them.

    Returns `false` when nothing changed, which is most frames.
    */
    bool takeCursorShape(out PointerShape shape) @safe pure nothrow @nogc
    {
        if (!shapePending)
            return false;
        shapePending = false;
        shape = pendingShape;
        return true;
    }

    /// Whether the inspector pane is shown (`<leader>vi` toggles it).
    bool inspVisible() const @safe pure nothrow
        => dock.layout.nodes.length && dock.layout.visible(inspPane);

    /// Builds the three-pane arrangement — called once, before `arrange`.
    private void buildLayout(int treeWidth) @safe
    {
        if (dock.layout.nodes.length)
            return;
        const t = dock.layout.addLeaf(treePane,
            extent: treeWidth < minTreeCols ? minTreeCols : treeWidth,
            minExtent: minTreeCols);
        const d = dock.layout.addLeaf(docPane);
        const ins = dock.layout.addLeaf(inspPane, extent: 40, minExtent: 20);
        foreach (leaf; [t, d, ins])
        {
            dock.layout.nodes[leaf].scrollGutterV = 1;
            dock.layout.nodes[leaf].scrollGutterH = 1;
        }
        dock.layout.root = dock.layout.addSplit(DockAxis.horizontal,
            [t, d, ins]);
        dock.layout.setVisible(inspPane, false);
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
        // The middle pane must stay flexible: a drag on the doc|inspector
        // divider hands its BEFORE node (the document) a fixed extent — the
        // gallery's reflexCentre finding — so it re-zeroes on every arrange.
        dock.layout.nodes[dock.layout.nodeOf(docPane)].extent = 0;
        dock.arrange(Rect(0, 0, w, h));

        tree.tv.scrollGutterV = 0;
        tree.tv.scrollGutterH = 0;
        viewer.externalScroll = true;
        insp.externalScroll = true;
        foreach (ref f; dock.paneFrames)
            if (f.pane == treePane)
            {
                tree.width = f.rect.width;
                tree.resize(f.rect.height);
            }
            else if (f.pane == inspPane)
            {
                insp.tv.width = f.rect.width;
                insp.tv.resize(f.rect.height);
                inspRect = f.rect;
            }
            else
            {
                viewer.originX = f.rect.x;
                viewer.resize(f.rect.width, f.rect.height);
                viewerRows = f.rect.height > 2 ? f.rect.height - 2 : 1;
            }
        if (!treeVisible)
            tree.width = 0; // the paint/hit helpers read this as "no pane"
        if (treeVisible)
            tree.rebuild();
        viewer.relayout();
        commitPaneScrolls();
    }

    private Rect inspRect;
    private int viewerRows = 1;

    // Pane models still own cursor/reveal policy; the dock owns the resulting
    // offsets and every pointer interaction with their outer bars. Chrome is
    // added to the vertical content extent because it is fixed inside the
    // pane while only the body rows scroll.
    private void publishPaneExtents() @safe
    {
        // `NAV6`: the extent, not the row count — a resize that pinned the
        // first line past the last full screen must survive the round trip
        // through the container's own clamp.
        dock.contentExtent(treePane, tree.contentCols,
            tree.tv.scrollExtent() + tree.chromeRows);
        dock.contentExtent(docPane, viewer.vm.contentCols,
            viewer.vm.scrollExtent() + 2);
        dock.contentExtent(inspPane, insp.tv.contentCols,
            insp.tv.scrollExtent() + insp.tv.chromeRows);
    }

    private void applyDockScrolls() @safe pure nothrow @nogc
    {
        tree.top = dock.offsetV(treePane);
        tree.hsb = tree.hsb.scrolledTo(dock.offsetH(treePane));
        viewer.vm.top = dock.offsetV(docPane);
        viewer.vm.hsb = viewer.vm.hsb.scrolledTo(dock.offsetH(docPane));
        insp.tv.top = dock.offsetV(inspPane);
        insp.tv.hsb = insp.tv.hsb.scrolledTo(dock.offsetH(inspPane));
    }

    private void commitPaneScrolls() @safe
    {
        publishPaneExtents();
        dock.scrollTo(treePane, tree.hsb.offset, tree.top);
        dock.scrollTo(docPane, viewer.vm.hsb.offset, viewer.vm.top);
        dock.scrollTo(inspPane, insp.tv.hsb.offset, insp.tv.top);
        applyDockScrolls();
    }

    /// Advances SCV8 and delivers the pane-local drag produced when content
    /// moved under a held pointer. The viewer's existing selection arm needs
    /// no autoscroll vocabulary of its own.
    private bool tickDock(Duration elapsed) @system
    {
        const dt = elapsed == Duration.max ? 0.0f
            : cast(float) elapsed.total!"msecs" / 1000.0f;
        const r = dock.tickScroll(dt, mousePointer);
        applyDockScrolls();
        if (r.kind != RouteKind.pane)
            return false;
        if (r.pane == docPane)
            viewer.handle(r.event);
        else if (r.pane == treePane && treeVisible)
            tree.handle(r.event);
        else if (r.pane == inspPane && inspVisible)
        {
            insp.handle(r.event, viewer.vm);
            syncInspectorExtent();
        }
        return true;
    }

    /// `<leader>vi` (drained from the viewer's command arm): toggles the
    /// inspector pane; opening seeds the selection from the top visible row
    /// (the viewer has no caret, deliberately) and focuses the pane.
    ///
    /// Sync starts one-way — tree→document — either way: the picker is
    /// disarmed on open (the `⌕` chip arms it) and on close (all sync ends
    /// with the panel).
    void toggleInspector() @system
    {
        dock.layout.setVisible(inspPane, !inspVisible);
        dock.focused = inspVisible ? inspPane : docPane;
        arrange(width, height);
        insp.pick(false);
        if (inspVisible)
        {
            insp.rebuild(viewer.vm);
            const t0 = viewer.vm.top;
            if (viewer.vm.rows.length && t0 >= 0
                && t0 < cast(long) viewer.vm.rows.length
                && viewer.vm.rows[cast(size_t) t0].srcStart != size_t.max)
                insp.selectAt(viewer.vm.rows[cast(size_t) t0].srcStart);
            syncInspectorExtent();
        }
        else
            viewer.vm.clearInspectExtent();
    }

    /// The tree→source half of the sync contract (`INS6`): tint the selected
    /// node's extent; scroll-follow only when it is fully off-screen.
    private void syncInspectorExtent() @system
    {
        size_t s, e;
        if (inspVisible && insp.selectedExtent(s, e))
        {
            viewer.vm.setInspectExtent(s, e);
            if (!viewer.vm.inspectExtentVisible(viewerRows))
                viewer.vm.scrollInspectIntoView(viewerRows);
        }
        else
            viewer.vm.clearInspectExtent();
    }

    private void paintInspector(ref Grid g) @system
    {
        import sparkles.ui.display_list : buildDisplayList;
        import sparkles.ui.geometry : SizeSpec;
        import sparkles.ui.layout : layout;
        import sparkles.ui.widget : Builder, Widget, WidgetKind;
        import sparkles.ui_tui : paintGrid;

        if (inspRect.width < 3)
            return;
        insp.ensureFresh(viewer.vm); // a document switch rebuilds next frame
        publishPaneExtents();
        applyDockScrolls();
        insp.focused = dock.focused == inspPane;
        auto b = Builder();
        const iv = insp.view(b, inspRect.width);
        Widget col = Widget(kind: WidgetKind.column, children: [iv],
            width: SizeSpec.fixed(inspRect.width), clipX: true);
        auto wt = b.finish(b.add(col));
        paintGrid(g, pageBg, buildDisplayList(wt, layout(wt),
            viewer.vm.palette, pageFg, pageBg),
            inspRect.x, inspRect.y,
            Rect(0, 0, inspRect.width, inspRect.height));
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
        if (inspVisible)
        {
            paintInspector(g);
            CellStyle div = page;
            div.fg = Color.fromRgb(toRgb(tree.theme.defaults.fg, pageFg));
            foreach (ref d; dock.dividers)
                foreach (y; d.rect.y .. d.rect.y + d.rect.height)
                    g.putText(cast(ushort) d.rect.x, cast(ushort) y, "│", div);
        }
        paintDockScrollbars(g);
        paintPicker(g);
    }

    /// The overlay's frame-stable geometry: two equal panels, sized by the
    /// terminal alone — never by the rows or the previewed file — so
    /// switching files cannot move a border (`PKL1`).
    package PickerGeometry pickerGeometry() const @safe pure nothrow @nogc
    {
        import picker_view : pickerGeometryFor;

        return pickerGeometryFor(width, height);
    }

    /**
    The fuzzy picker (`PIK3`), over everything: the shared widget tree
    (`picker_view`), interpreted through the same cell canvas the guide
    uses — so the window and the terminal cannot drift on what it looks
    like. The preview panel's framed hole is then filled with the live
    document pane's own cells (`picker_preview`).
    */
    private void paintPicker(ref Grid g) @system
    {
        import picker_view : pickerPreviewRect;
        import sparkles.ui.display_list : buildDisplayList;
        import sparkles.ui.geometry : Constraints;
        import sparkles.ui.layout : layout;
        import sparkles.ui.style : defaultTwoslashPalette, schemeForBackground;
        import sparkles.ui_tui : paintGrid;

        if (picker.empty || !picker.get.state.active)
            return;
        const geometry = pickerGeometry();
        auto view = picker.get.buildView(geometry);
        auto frames = layout(view,
            Constraints(maxW: 2 * geometry.panelCols));
        const panel = frames[view.root].rect;
        const x = (width - panel.width) / 2;
        const originX_ = x > 0 ? x : 0;
        paintGrid(g, pageBg, buildDisplayList(view, frames,
            defaultTwoslashPalette(schemeForBackground(pageBg)), pageFg,
            pageBg), originX_, 1,
            Rect(0, 0, panel.width, height > 2 ? height - 2 : height));

        // The document pane paints its own grid; its cells land in the hole.
        const hole = pickerPreviewRect(view, frames);
        if (pickerDoc is null || hole.width <= 0 || hole.height <= 0)
            return;
        auto pane = &pickerDoc.paint(hole.width, hole.height);
        foreach (y; 0 .. pane.rows)
        {
            const dy = 1 + hole.y + y;
            if (dy < 0 || dy >= height)
                continue;
            foreach (px; 0 .. pane.cols)
            {
                const dx = originX_ + hole.x + px;
                if (dx < 0 || dx >= width)
                    continue;
                g[cast(ushort) dx, cast(ushort) dy]
                    = (*pane)[cast(ushort) px, cast(ushort) y];
            }
        }

        // The preview's bar is the pane's OWN machine (`vm.scroll`), painted
        // the same way `paintDockScrollbars` paints the viewer's — one look,
        // one animation, whichever pane you are reading.
        const lay = pickerDoc.bars;
        if (lay.vLive)
        {
            import sparkles.ui.components.chrome : scrollbar, ScrollbarGlyphs;
            import sparkles.ui.widget : Builder;

            const sv = pickerDoc.pane.vm.scroll;
            auto b = Builder();
            const bar = scrollbar(b, sv.v,
                lay.vExtents.content, lay.vExtents.viewport,
                lay.vExtents.track, ScrollbarGlyphs('█', '░'),
                expandPercent: cast(ubyte) sv.vAnim.percent,
                gutter: lay.vTrack.width,
                trackLit: sv.v.hovered || sv.v.dragging);
            auto t = b.finish(bar);
            paintGrid(g, pageBg, buildDisplayList(t, layout(t),
                pickerDoc.pane.vm.palette, pageFg, pageBg),
                originX_ + hole.x + lay.vTrack.x, 1 + hole.y + lay.vTrack.y);
        }
    }

    /// Paints the semantic bars the dock routed. The terminal degradation is
    /// the same `WidgetKind.scrollbar` path standalone panes use; only the
    /// geometry and state owner changed.
    private void paintDockScrollbars(ref Grid g) @system
    {
        import sparkles.ui.components.chrome : scrollbar, ScrollbarGlyphs;
        import sparkles.ui.display_list : buildDisplayList;
        import sparkles.ui.layout : layout;
        import sparkles.ui.widget : Builder;
        import sparkles.ui_tui : paintGrid;

        foreach (ref const barFrame; dock.bars)
        {
            const sv = dock.scrollOf(barFrame.pane);
            const pal = barFrame.pane == treePane
                ? tree.palette : viewer.vm.palette;
            if (barFrame.hLive)
            {
                auto b = Builder();
                const bar = scrollbar(b, sv.h,
                    barFrame.hExtents.content, barFrame.hExtents.viewport,
                    barFrame.hExtents.track, ScrollbarGlyphs('━', '─'),
                    expandPercent: cast(ubyte) sv.hAnim.percent,
                    gutter: barFrame.hTrack.height,
                    trackLit: sv.h.hovered || sv.h.dragging);
                auto t = b.finish(bar);
                paintGrid(g, pageBg, buildDisplayList(t, layout(t), pal,
                    pageFg, pageBg), barFrame.hTrack.x, barFrame.hTrack.y);
            }
            if (barFrame.vLive)
            {
                auto b = Builder();
                const bar = scrollbar(b, sv.v,
                    barFrame.vExtents.content, barFrame.vExtents.viewport,
                    barFrame.vExtents.track, ScrollbarGlyphs('█', '░'),
                    expandPercent: cast(ubyte) sv.vAnim.percent,
                    gutter: barFrame.vTrack.width,
                    trackLit: sv.v.hovered || sv.v.dragging);
                auto t = b.finish(bar);
                paintGrid(g, pageBg, buildDisplayList(t, layout(t), pal,
                    pageFg, pageBg), barFrame.vTrack.x, barFrame.vTrack.y);
            }
        }
    }

    /// The open document's path — what the file watcher (`WCH1`) re-arms
    /// on and what a reload re-reads. Empty for an embedded document.
    string currentDocPath;
    /// Set by the watch fiber on a write-close of the open document; the
    /// loop's poll pass turns it into `reloadCurrent`.
    package bool reloadPending;
    /// The armed watch (loop-owned bookkeeping: the directory and its wd).
    package string watchedDir;
    /// ditto
    package int watchedWd = -1;
    version (linux)
    {
        /// The one inotify instance for document reloads (`WCH1`). Heap so
        /// the workspace stays copy-friendly for tests.
        private Watcher* docWatcher;
        /// Whether the watch daemon is parked on the host's scope.
        private bool docWatchArmed;
    }

    /// Reloads the open document from disk in place (`WCH2`): the same
    /// loader, the viewport preserved, the retained parse and the inspector
    /// rebuilt against the new content. The extent tint clears — the old
    /// selection's byte extent is meaningless against a changed file; the
    /// next hover re-syncs.
    void reloadCurrent() @system
    {
        if (currentDocPath.length == 0)
            return;
        const keepTop = viewer.vm.top;
        openDoc(currentDocPath);
        viewer.vm.top = keepTop < cast(long) viewer.vm.rows.length
            ? keepTop : (viewer.vm.rows.length
                ? cast(long) viewer.vm.rows.length - 1 : 0);
        if (inspVisible)
        {
            insp.rebuild(viewer.vm);
            insp.lastSyncOffset = size_t.max;
            viewer.vm.clearInspectExtent();
        }
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
        currentDocPath = path;
        viewer.setDocument(doc.title, doc.source, doc.events, doc.preview,
            startPreview: true, doc.twoslash, doc.lang, doc.diffDoc,
            doc.diffSides, doc.diffSession, doc.diffEmphasis,
            doc.coverage, doc.hasCoverage);
        viewer.docNote = doc.dsvNote;
        viewer.vm.docPath = path; // .editorconfig discovery (format preview)
        viewer.dsvCopy = DsvCopy.of(doc.dsvText, doc.dsvInfo);
        viewer.tableFmt = resolveTableCopy(tableCopyFlag, doc.dsvInfo.present);
        dsvBrowser = DsvBrowser.init;
        wireDsvHooks();
        syncTreeSession();
        startDiffTypes();
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
        stopDiffTypes();
        if (live is null)
            return;
        live.shutdown();
        live = null;
    }

    /**
    `DVT1`/`T0`: starts one analyzer per side of a two-file `.d` diff.

    Scoped to the case where both sides are files on disk (`hue --diff a.d
    b.d`), because that is the one the analyzer can answer without a
    materialized revision (`DVT2`). Anything else — a git-sourced side, a
    non-`.d` file, more than one changed file — leaves the diff exactly as it
    renders without types.
    */
    package void startDiffTypes() @system
    {
        import std.algorithm.searching : endsWith;
        import std.file : exists, isFile;

        stopDiffTypes();
        if (!liveTypes || !viewer.diffNav())
            return;
        const entries = viewer.diffEntries();
        if (entries.length != 1)
            return;
        const paths = [entries[0].oldPath, entries[0].newPath];
        foreach (i, p; paths)
        {
            if (!p.endsWith(".d"))
                return;
            bool ok;
            try
                ok = p.exists && p.isFile;
            catch (Exception)
                ok = false;
            if (!ok)
                return;
        }
        viewer.ensureDiffTypes(1);
        foreach (i, p; paths)
        {
            string reason;
            diffLive[i] = LiveTypesSession.start(p, reason,
                silenceChildStderr: true);
            if (diffLive[i] is null && !liveNotice.length)
                liveNotice = reason;
        }
    }

    /// ditto
    package void stopDiffTypes() @system
    {
        foreach (ref s; diffLive)
        {
            if (s is null)
                continue;
            s.shutdown();
            s = null;
        }
    }

    /// Drains both diff oracles; returns `true` when something changed and
    /// the frame needs a repaint. A side whose payload does not describe that
    /// side's text is refused by `TypeOverlay.attach` and simply stays plain.
    package bool pollDiffTypes() @system
    {
        bool changed;
        foreach (i, s; diffLive)
        {
            if (s is null)
                continue;
            s.poll();
            if (s.payloadReady)
            {
                viewer.attachDiffTypes(0, i == 0, s.takePayload());
                changed = true;
            }
            if (s.failed)
            {
                if (!liveNotice.length)
                    liveNotice = s.reason;
                s.shutdown();
                diffLive[i] = null;
            }
        }
        return changed;
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
    /// Toggle the explorer pane; focus follows (XPL2). Reached through the
    /// panes' `toggleExplorer` intent flags — `e` and `<leader>e` alike.
    private void toggleExplorerPane() @system
    {
        treeVisible = !treeVisible;
        treeFocused = treeVisible;
        arrange(width, height);
    }

    private bool viewerHasDiffSession() const @safe pure nothrow @nogc
        => viewer.diffNav();

    /// `TVU6`: point the explorer at the open document's changed-file session
    /// (or back at the filesystem when it is not a diff). Called wherever the
    /// viewer's document changes, so the two panes never disagree about what
    /// is being shown.
    /// Re-renders the current DSV document under the browser's projection
    /// (`DSB1`): re-adapt (no re-sniff — the resolved dialect is replayed),
    /// rebuild the preview, and re-arm the copy state; scroll resets, the
    /// keymap and format survive.
    void applyDsvBrowser() @system
    {
        import gui_preview : previewOf;
        import sparkles.syntax : HighlightEvent;

        auto st = viewer.dsvCopy;
        if (!st.info.present)
            return;
        auto proj = dsvBrowser.projection(st.info.columns);
        proj.rowMask = fuzzyRowMask(st.rawText, st.info, dsvBrowser.fuzzyParts);
        auto adapted = adaptDsv(st.rawText, "", flagsOf(st.info), proj);
        auto pm = previewOf(*viewer.cache, adapted.doc);
        pm.tableExtras = adapted.extras;
        auto ev = new HighlightEvent[](1);
        ev[0] = HighlightEvent.sourceSpan(0, adapted.text.length);
        const fmt = viewer.tableFmt;
        const path = viewer.vm.docPath;
        viewer.setDocument(viewer.vm.title, adapted.text, ev, pm,
            startPreview: true);
        viewer.vm.docPath = path;
        const chrome = dsvBrowser.chromeNote;
        viewer.docNote = dsvStatusNote(adapted.info)
            ~ (chrome.length ? " · " ~ chrome : "");
        viewer.dsvCopy = DsvCopy.of(st.rawText, adapted.info, proj);
        viewer.tableFmt = fmt;
        wireDsvHooks();
    }

    /// The viewer reports browser intent; the workspace owns the state and
    /// the reprojection (`DSB`).
    void wireDsvHooks() @system
    {
        viewer.onDsvSort = (uint col, bool append) @system {
            dsvBrowser.cycleSort(col, append);
            applyDsvBrowser();
        };
        viewer.onDsvReset = () @system {
            dsvBrowser.reset();
            applyDsvBrowser();
        };
        viewer.onDsvFilterApply = (string q) @system {
            const st = viewer.dsvCopy;
            if (!st.info.present)
                return;
            if (dsvBrowser.setFilter(q, st.headerNames))
                applyDsvBrowser();
            else
                viewer.showNotice("filter: " ~ dsvBrowser.filterError);
        };
    }

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
        if (formatPreviewRulerDragging(viewer.vm))
            return PointerShape.ewResize; // the ruler grab (`RUL3`)
        if (viewer.vm.barGrabbing)
            return viewer.vm.barShape();
        return PointerShape.default_;
    }

    /// ditto
    private PointerShape paneHoverShape() @safe pure nothrow @nogc
    {
        if (viewer.rulerHovering)
            return PointerShape.ewResize; // the ruler hover (`RUL3`/`RUL6`)
        return viewer.vm.barShape();
    }

    /// Applies one event; returns false to quit.
    /// How long until the key guide's panel would appear — the loop's second
    /// deadline (`LTN4`). `Duration.max` when nothing is pending, i.e. block
    /// until a key arrives.
    Duration untilLanternShown() const @safe pure nothrow @nogc
    {
        const a = viewer.untilLanternShown();
        const b = tree.untilLanternShown();
        return a < b ? a : b;
    }

    /// Advances both panes' guide clocks after a wait expires.
    void tickLantern(Duration elapsed) @safe pure nothrow @nogc
    {
        viewer.tickLantern(elapsed);
        tree.tickLantern(elapsed);
    }

    /// Opens the fuzzy file picker (`<leader>ff`, `PKS1`) over the tree's
    /// root, with the explorer's include/exclude globs. Reopening re-walks
    /// the corpus, so files created since the last open are found.
    package void openPicker() @system
    {
        if (picker.empty)
            picker = makeUnique!PickerHost();
        if (pickerDoc is null)
            pickerDoc = new PickerDocPane;
        // The preview pane is wired exactly like the main viewer: the same
        // loader, themes, labels, grammar cache and ANSI decoder — it IS the
        // document pane, opened on whatever the selection rests on.
        pickerDoc.load = loadDoc;
        pickerDoc.pane.names = viewer.names;
        pickerDoc.pane.themes = viewer.themes;
        pickerDoc.pane.labels = viewer.labels;
        pickerDoc.pane.vm.cache = viewer.vm.cache;
        pickerDoc.pane.vm.decodeAnsi = viewer.vm.decodeAnsi;
        pickerDoc.caps = mousePointer; // the same profile the dock eases with
        pickerDoc.syncTheme(viewer.themeIndex);
        picker.get.open(tree.root.length ? tree.root : ".",
            tree.includeGlobs, tree.excludeGlobs);
        dirty = true;
    }

    bool handle(in Event e) @system
    {
        // The fuzzy picker is a modal surface (`PIK1`): while it is open it
        // owns the whole keyboard AND the pointer — keys route by pane
        // focus, wheel and presses by position (`DCK7` inside the modal:
        // the element under the cursor, never a pane beneath the overlay).
        if (!picker.empty && picker.get.state.active)
        {
            void apply(PickerAction a) @system
            {
                final switch (a)
                {
                case PickerAction.consumed:
                    break;
                case PickerAction.preview:
                    // Forwarded to the document pane, whose own input
                    // surface applies — keys, wheel, scrollbar grabs alike.
                    if (pickerDoc !is null)
                        pickerDoc.forward(picker.get.previewEvent);
                    break;
                case PickerAction.closed:
                    if (pickerDoc !is null)
                        pickerDoc.close();
                    break;
                case PickerAction.accepted:
                    if (pickerDoc !is null)
                        pickerDoc.close();
                    openDoc(picker.get.acceptedPath);
                    break;
                }
            }

            // Overlay-local translation: `paintPicker` centers the overlay
            // at row 1, and events route against the same arithmetic — the
            // panel is frame-stable, so both derive one origin.
            const pkGeometry = pickerGeometry();
            const pkX = (width - 2 * pkGeometry.panelCols) / 2;
            const overlayX = pkX > 0 ? pkX : 0;
            e.match!(
                (in KeyEvent k) { apply(picker.get.handleKey(k)); },
                (in PointerEvent p) {
                    PointerEvent local = p;
                    local.pos = Point(p.pos.x - overlayX, p.pos.y - 1);
                    apply(picker.get.handleOverlay(Event(local), pkGeometry));
                },
                (in WheelEvent w) {
                    WheelEvent local = w;
                    local.pos = Point(w.pos.x - overlayX, w.pos.y - 1);
                    apply(picker.get.handleOverlay(Event(local), pkGeometry));
                },
                (_) {});
            return true;
        }

        // Workspace-level commands the panes cannot answer — resolved by the
        // ONE table with the workspace's own context, never by a key switch
        // (this block was the policy's surviving fourth copy). Guarded off
        // while a pane consumes typed text or has a key sequence pending: a
        // key that is the tail of a `<leader>…` path belongs to that pane's
        // lantern, not to an interception.
        const typing = (treeFocused && tree.inputActive)
            || (!treeFocused && viewer.inputActive);
        if (!typing && !tree.lanternPending && !viewer.lanternPending)
        {
            import keymap : Command, commandFor, KeyContext;

            bool handled;
            e.match!((in KeyEvent k) {
                const ctx = KeyContext(
                    treeFocused: treeFocused, treeVisible: treeVisible,
                    hasDiffSession: viewerHasDiffSession,
                    hasDocSet: currentDocPath.length != 0);
                // With the tree focused the brackets resolve to the pane's
                // own commands (next/prev git change) and fall through to
                // it; the viewer-scope rows carry the `DVG1` precedence — a
                // diff session's files ahead of document navigation (XPL4).
                switch (commandFor(k, ctx).cmd)
                {
                    case Command.diffPrevFile:
                        viewer.moveDiffFile(-1);
                        handled = true;
                        break;
                    case Command.diffNextFile:
                        viewer.moveDiffFile(+1);
                        handled = true;
                        break;
                    case Command.setPrev:
                        openAdjacent(-1);
                        handled = true;
                        break;
                    case Command.setNext:
                        openAdjacent(+1);
                        handled = true;
                        break;
                    default:
                        break; // the panes' own commands route below
                }
            }, (_) {});
            if (handled)
                return true;
        }

        // Everything positional — and the keys the panes own — is routed by
        // the container (DCK13): capture first, then dividers, then the
        // pane under the pointer, with coordinates already pane-local.
        const r = dock.handle(e);
        // Routing refreshed both divider and bar hover from the very frames
        // paint consumes. Compose content-level fence chrome after it.
        e.match!((in PointerEvent p) {
            const grabbed = dock.resizing
                || dock.scrollOf(treePane).grabbing
                || dock.scrollOf(docPane).grabbing
                || dock.scrollOf(inspPane).grabbing
                || paneGrabShape() != PointerShape.default_;
            const want = dock.shape(paneGrabShape(), paneHoverShape());
            if (want != curShape || (grabbed && p.action == PointerAction.drag))
            {
                curShape = want;
                pendingShape = want;
                shapePending = true;
            }
        }, (_) {});
        if (r.kind == RouteKind.container)
        {
            // A divider drag: the container resized the layout, the panes
            // are told their new rects.
            if (r.relayout)
                arrange(width, height);
            else
                applyDockScrolls();
            return true;
        }
        if (r.kind == RouteKind.none)
            return true;
        const ev = r.event;

        // A wheel remains pane policy, but the outer offset is container
        // state. The document gets first refusal for a nested fence; the two
        // tree panes are plain viewports.
        bool wheel;
        ev.match!((in WheelEvent w) {
            wheel = true;
            if (r.pane == docPane)
            {
                viewer.handle(ev);
                publishPaneExtents();
                dock.scrollTo(docPane, viewer.vm.hsb.offset, viewer.vm.top);
            }
            else
                dock.scrollBy(r.pane, w.dx + (w.mods.shift ? w.dy : 0),
                    w.mods.shift ? 0 : w.dy);
            applyDockScrolls();
            tickDock(Duration.zero);
        }, (_) {});
        if (wheel)
            return true;

        if (r.pane == inspPane && inspVisible)
        {
            if (!insp.handle(ev, viewer.vm))
            {
                toggleInspector(); // close intent (q/Escape)
                return true;
            }
            syncInspectorExtent();
            commitPaneScrolls();
            return true;
        }
        const toTree = r.pane == treePane;

        if (toTree && treeVisible)
        {
            const alive = tree.handle(ev);
            if (tree.pickerRequested) // `<leader>ff` with the tree focused
            {
                tree.pickerRequested = false;
                openPicker();
                return true;
            }
            if (tree.explorerToggleRequested) // `e` / `<leader>e`
            {
                tree.explorerToggleRequested = false;
                toggleExplorerPane();
                return true;
            }
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
            else
                commitPaneScrolls();
            return true;
        }
        const alive = viewer.handle(ev);
        syncTreeTheme();
        if (viewer.inspectorToggleRequested)
        {
            viewer.inspectorToggleRequested = false;
            toggleInspector();
        }
        if (viewer.pickerRequested) // `<leader>ff` from the document pane
        {
            viewer.pickerRequested = false;
            openPicker();
        }
        if (viewer.explorerToggleRequested) // `e` / `<leader>e`
        {
            viewer.explorerToggleRequested = false;
            toggleExplorerPane();
        }
        // INS6 source→tree, the picker half (DevTools' semantics): while the
        // `⌕` chip is armed, hovering the document walks the tree live, and a
        // left click DISARMS it — the reader has chosen that node, and every
        // later mouse move must leave it alone.
        if (inspVisible && insp.picking)
            ev.match!((in PointerEvent p) {
                const off = viewer.offsetAt(p.pos);
                if (off >= 0 && cast(size_t) off != insp.lastSyncOffset)
                {
                    insp.lastSyncOffset = cast(size_t) off;
                    insp.selectAt(cast(size_t) off);
                    syncInspectorExtent();
                }
                if (p.action == PointerAction.press
                    && p.button == PointerButton.left)
                    insp.picking = false;
            }, (_) {});
        commitPaneScrolls();
        return alive;
    }

    // ── the component contract (`P2.B5`) ────────────────────────────────────

    /**
    Whether an event reached this pass.

    Both loop arms knew by construction — an expired deadline and a delivered
    event came out of different branches. A component is only told about
    events, so the distinction has to be remembered: it is what separates
    "nothing happened, tick the guide's clock and check the git worker" from
    "a key arrived".
    */
    private bool sawEvent = true;

    /// The deadline the previous pass asked for (`HST16`), so an expiry knows
    /// how much time to advance the guide's clock by (`LTN4`).
    private Duration lastAsk = Duration.max;

    /// Whether a repaint is due. Inverted into `skipFrame` (`HST9`): the
    /// default is to draw, and an idle pass that changed nothing declines —
    /// which is what keeps an untouched document emitting no bytes at all.
    private bool dirty = true;

    /// The per-pass drains both arms run before anything else: an arriving
    /// payload or tip must paint in the same pass it landed in.
    package bool pollAll() @system
    {
        bool changed = pollLive();
        changed |= pollDiffTypes();
        // The picker's scheduler publishes its newest partial page here —
        // and, in the synchronous degradation (`PIK8`), takes its next
        // duration-bounded step. The preview pane's debounce/dwell clocks
        // advance with it.
        if (!picker.empty && picker.get.poll())
            changed = true;
        if (!picker.empty && picker.get.state.active && pickerDoc !is null)
        {
            pickerDoc.select(picker.get.selectedPath);
            pickerDoc.syncTheme(viewer.themeIndex);
            changed |= pickerDoc.tick();
        }
        // Format preview (`FPR9`): an applied buffer must paint this pass.
        changed |= formatPreviewPump(viewer.vm);
        if (tree.git.poll())
        {
            tree.rebuild();
            changed = true;
        }
        // File monitoring (`WCH2`): a pending reload applies before the frame
        // paints so the viewer never shows a stale buffer for one more pass.
        version (linux)
            if (reloadPending)
            {
                reloadPending = false;
                reloadCurrent();
                changed = true;
            }
        return changed;
    }

    /**
    The frame's pre-render half.

    Returns an $(B empty) tree: hue paints its own cells, so the work is in
    `paint` (`HST13`) and this is the decision half — drain, re-arrange if the
    terminal moved, hand the terminal its out-of-band sequences, ask for the
    next wake, and decide whether there is anything to draw at all.
    */
    /// Whether the git driver and the oracle watchers are installed. Retried
    /// each frame until it takes: `spawnDaemon` only answers once the arm's
    /// scope exists, which is after the setup phase and before the first one.
    private bool gitDriverArmed;
    /// The oracle sessions already watched, by slot. A replaced session's
    /// watcher exits on its own (its fd turns -1), so a changed slot is the
    /// signal to park a new one.
    private LiveTypesSession*[3] watched;

    /**
    Parks this run's background work on the loop's own scope (`HST15`).

    Two kinds, and both replace a poll: an oracle watcher turns "is the pipe
    readable" into a parked read, retiring the 33 ms tick; the git driver turns
    the status refresh into spawned children on the ring, retiring the 150 ms
    cap. Where the host offers neither — the blocking arm, the recorder, a
    foreign embedding — nothing is armed and the deadlines below stay the
    polled ones, which is the same code either way.
    */
    void armDaemons(H)(ref H h)
    {
        import sparkles.ui_app.host : canSpawnDaemon;

        static if (canSpawnDaemon!H)
        {
            import sparkles.event_horizon.backend.concept : canSubmitOp;
            import sparkles.event_horizon.backend.select : DefaultBackend;
            import sparkles.event_horizon.op : OpPollAdd, OpWaitid;

            // What this backend lets the loop own outright.
            enum liveWatchable = canSubmitOp!(DefaultBackend, OpPollAdd);
            enum gitAsync = canSubmitOp!(DefaultBackend, OpWaitid);

            // `ref` locals (2.111), not addresses: a closure over a `ref`
            // variable refers to the variable's referent, which is what the
            // old `&this`/`&h` dance was buying — at the cost of a `@trusted`
            // lambda apiece and a pointer everything downstream had to
            // dereference. Both referents outlive the run: the workspace by
            // the entry point's frame, the host by its loop's.
            ref WorkspaceTui self = this;
            ref H host = h;

            static if (gitAsync)
                if (!gitDriverArmed)
                {
                    // A root change wipes the cache, delegate included, so
                    // this re-installs whenever it went missing.
                    if (tree.git.asyncSpawn is null)
                        tree.git.asyncSpawn = (string root, uint gen) {
                            gitDriverArmed = host.spawnDaemon(() {
                                refreshGitStatus(self, host, root, gen);
                            });
                        };
                    else
                        gitDriverArmed = true;
                }

            static if (liveWatchable)
            {
                LiveTypesSession*[3] sessions = [live, diffLive[0], diffLive[1]];
                foreach (i, s; sessions)
                    if (s !is watched[i])
                    {
                        watched[i] = s;
                        if (s !is null)
                            // A real function frame per call: a closure
                            // declared in a loop captures ONE shared slot,
                            // so each watcher gets its own through a call.
                            watchSession(host, s);
                    }
            }

            // Document file monitoring (`WCH1`): one inotify daemon parks on
            // the open document's DIRECTORY (editors save by rename, so the
            // file's own inode dies). A write-close or rename-in whose name
            // matches marks the reload and wakes the loop. Re-arms whenever
            // the open document's directory changes; a stale watch simply
            // produces non-matching events.
            version (linux)
            {
                import core.sys.linux.sys.inotify : IN_CLOSE_WRITE, IN_MOVED_TO;
                import std.path : dirName;

                if (!docWatchArmed)
                {
                    if (docWatcher is null)
                    {
                        auto w = new Watcher;
                        if (!Watcher.create(*w).hasError)
                            docWatcher = w;
                    }
                    if (docWatcher !is null)
                        docWatchArmed = host.spawnDaemon(() {
                            watchDocuments(self, host);
                        });
                }
                if (docWatcher !is null && currentDocPath.length)
                {
                    const dir = dirName(currentDocPath);
                    if (dir != watchedDir)
                    {
                        auto ar = docWatcher.addWatch(dir,
                            IN_CLOSE_WRITE | IN_MOVED_TO);
                        if (!ar.hasError)
                        {
                            watchedDir = dir;
                            watchedWd = ar.value;
                        }
                    }
                }
            }
        }
    }

    /// ditto — one watcher, spawned with its own `sess`.
    private void watchSession(H)(ref H h, LiveTypesSession* sess)
    {
        ref H host = h;
        cast(void) host.spawnDaemon(() { watchOracle(host, sess); });
    }

    WidgetTree view(H)(ref H h)
    {
        // A frame after the quit is a frame nobody sees — the arm's loop
        // condition ends the run the moment this pass returns. The old loop
        // got this for free by breaking on `handle`'s `false`; a component is
        // asked to present first and has to decline. Measurable, not
        // theoretical: without it the terminal gets one more
        // synchronized-update bracket on the way out.
        if (h.quitRequested)
        {
            h.skipFrame();
            return WidgetTree.init;
        }

        armDaemons(h);
        dirty |= pollAll();

        // A pass with no event is a deadline that expired.
        if (!sawEvent)
            dirty |= onWaitExpired(this, lastAsk);
        sawEvent = false;

        const sz = h.size;
        if (sz.width != width || sz.height != height)
        {
            arrange(sz.width, sz.height);
            dirty = true;
        }

        // Before the frame, and as errands rather than sequences: both of
        // these address the target itself rather than the cell surface, and
        // the host is what knows how this one carries them — OSC 52 and
        // OSC 22 on a terminal, the window system's own calls in a window.
        const clip = viewer.takeClipboard();
        if (clip.length)
            h.clipboard(clip);
        PointerShape shape;
        if (takeCursorShape(shape))
            h.pointerShape(shape);

        // `HST16`: the lantern panel's remainder, capped by the live oracle's
        // tick and by a git refresh in flight — a deadline that moves every
        // pass, which is exactly what `idleTimeoutMs` could not express.
        lastAsk = waitDeadline(this);
        if (lastAsk != Duration.max)
            h.wakeIn(lastAsk);

        if (!dirty)
            h.skipFrame();
        dirty = false;
        return WidgetTree.init;
    }

    /// One event. A resize is not routed — the next `view` re-measures against
    /// the host's size and re-arranges, which is where that knowledge lives.
    void handle(H)(ref H h, in Event e)
    {
        sawEvent = true;
        dirty = true;
        if (e.match!((in ResizeEvent _) => true, _ => false))
            return;
        if (!handle(e))
            h.quit();
    }

    /// The renderer, inside the frame the host opened (`HST13`): hue's own
    /// cells, painted through the host's grid.
    void paint(H)(ref H h, in WidgetTree, in Frame[])
    {
        // A host with no cell grid has nothing to paint into. That is the
        // recorder, and it is not a gap: hue emits no display-list operations
        // at all — its frame IS cells — so what a recorded run has to say is
        // what `view` decided (drew or declined, asked to wake when, wrote
        // which sequence out of band), which it captures exactly.
        static if (__traits(compiles, h.grid))
            paint(h.grid);
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
    bool liveTypes = true,
    DiffLayout diffLayout = DiffLayout.unified,
    OverflowPolicy codeOverflow = OverflowPolicy.init,
    int codeMaxLines = -1,
    OverflowPolicy tableOverflow = OverflowPolicy.init,
    int tableMaxLines = -1,
    WorkspaceDoc delegate() @system reloadDiff = null,
    bool formatPreview = false, int formatWidth = 0,
    string formatterName = null,
    string tableCopyFlag = "auto",
    ScrollAnchorMode scrollAnchor = ScrollAnchorMode.segment) @system
{
    WorkspaceTui w;
    // The picker's worker pool and the preview's oracle must stop before the
    // process exits.
    scope (exit) if (!w.picker.empty) w.picker.get.shutdown();
    scope (exit) if (w.pickerDoc !is null) w.pickerDoc.shutdown();
    w.loadDoc = loadDoc;
    w.tableCopyFlag = tableCopyFlag;
    // `DST2`: after a patch is applied the diff on screen is stale — the rows
    // just staged are no longer part of it. Only the host owns the loader
    // that produced the document, so it hands one back.
    if (reloadDiff !is null)
        w.viewer.onStaged = () @system {
            auto fresh = reloadDiff();
            w.viewer.setDocument(fresh.title, fresh.source, fresh.events,
                fresh.preview, startPreview: true, fresh.twoslash, fresh.lang,
                fresh.diffDoc, fresh.diffSides, fresh.diffSession,
                fresh.diffEmphasis, fresh.coverage, fresh.hasCoverage);
            w.viewer.docNote = fresh.dsvNote;
            w.viewer.dsvCopy = DsvCopy.of(fresh.dsvText, fresh.dsvInfo);
            w.viewer.tableFmt = resolveTableCopy(w.tableCopyFlag,
                fresh.dsvInfo.present);
            w.dsvBrowser = DsvBrowser.init;
            w.wireDsvHooks();
        };
    w.liveTypes = liveTypes;
    // `DVL3`: the layout the reviewer asked for on the command line; `s`
    // toggles it, and a narrow pane degrades it at render time.
    w.viewer.vm.diffLayout = diffLayout;
    // `NAV5`: what a terminal resize re-finds at the top of the pane.
    w.viewer.vm.anchorMode = scrollAnchor;
    w.viewer.vm.codeOverflow = codeOverflow;
    w.viewer.vm.codeMaxLines = codeMaxLines;
    w.viewer.vm.tableOverflow = tableOverflow;
    w.viewer.vm.tableMaxLines = tableMaxLines;
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
            initial.diffSession, initial.diffEmphasis,
            initial.coverage, initial.hasCoverage);
        w.viewer.docNote = initial.dsvNote;
        w.viewer.vm.docPath = isDir ? null : target;
        // `FMV8`: --format-preview starts the session on the opening file.
        if (formatPreview)
            w.viewer.showNotice(formatPreviewStart(w.viewer.vm,
                formatWidth, formatterName));
        w.viewer.dsvCopy = DsvCopy.of(initial.dsvText, initial.dsvInfo);
        w.viewer.tableFmt = resolveTableCopy(tableCopyFlag,
            initial.dsvInfo.present);
        w.dsvBrowser = DsvBrowser.init;
        w.wireDsvHooks();
        w.syncTreeSession();
        w.startDiffTypes();
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
        scope (exit) w.stopLive();

        // The loop is the host's (`HST1`). Its terminal arm is the code this
        // module used to carry twice over: the event-horizon shape (input and
        // SIGWINCH as fibers feeding one channel, the workspace in the root
        // fiber, a single ring wait on a deadline that moves every pass) and
        // the blocking fallback for a platform or sandbox without a ring —
        // selected once, reported, never silently forked.
        //
        // `motion: true` is any-event tracking (1003): bare pointer motion
        // reports too, so the divider can show a hover resize cursor.
        RunConfig cfg = {
            title: "hue",
            motion: true,
            backend: Backend.tui,
            autoBackend: false,
        };
        // The sink was already decided — `main` reaches this only for the
        // terminal — so the policy states it rather than re-probing.
        BackendPolicy policy = {
            forceTui: true,
            stdinTty: true,
            stdoutTty: true,
        };

        final switch (run!(
            (ref h) { cast(void) w.view(h); },
            (ref h, in Event e) { w.handle(h, e); },
            (ref h) { w.paint(h, WidgetTree.init, null); },
        )(cfg, policy))
        {
            case RunOutcome.ok:
                break;
            case RunOutcome.openFailed:
                return 1; // raw mode refused: nothing was drawn
            case RunOutcome.noBackend:
            case RunOutcome.notInteractive:
                return 1;
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

/**
One oracle watcher (`HST15`): parks until the oracle's stdout is readable,
wakes the host, and re-arms.

The loop's poll pass does the draining — a watcher only converts readability
into a wakeup. It exits when the session ends (its fd turns -1); at worst one
spurious wake follows a drained burst (the readiness op completed before the
drain), which the poll pass answers with "no change" and no repaint.
*/
private void watchOracle(H)(ref H h, LiveTypesSession* session) @system
{
    import sparkles.event_horizon.io : waitReadable;
    import sparkles.event_horizon.sched : currentScheduler, onScheduler, Sched;

    if (!onScheduler)
        return; // nothing parked us; the polled tick still covers this

    // The loop that resumed this fiber. A daemon body is handed a plain
    // delegate — the host publishes no scheduler, because two of its three
    // targets have none — so it asks once, here, and by `ref`.
    ref Sched sched = currentScheduler();

    for (;;)
    {
        const fd = session.readFd;
        if (fd < 0)
            return; // failed, shut down, or replaced
        if (waitReadable(sched, fd).hasError)
            return;
        h.wake();
    }
}

/**
Document file watcher (`WCH1`): parks on the workspace's one inotify
descriptor; a write-close (or rename-in — how editors save) whose name
matches the open document marks the reload and wakes the loop.
*/
version (linux)
private void watchDocuments(H)(ref WorkspaceTui w, ref H h) @system
{
    import std.path : baseName;
    import sparkles.event_horizon.sched : currentScheduler, onScheduler, Sched;

    if (!onScheduler || w.docWatcher is null)
        return;
    ref Sched sched = currentScheduler();

    for (;;)
    {
        auto ev = w.docWatcher.nextEvent(sched);
        if (ev.hasError)
            return; // descriptor closed: the loop is tearing down
        if (w.currentDocPath.length
            && ev.value.wd == w.watchedWd
            && ev.value.name == baseName(w.currentDocPath))
        {
            w.reloadPending = true;
            h.wake();
        }
    }
}

/**
One git refresh (`HST15`): the `GitStatusCache.asyncSpawn` driver — the worker
thread re-shaped as spawned children on the ring.

Failures deliver `ok: false`, exactly like the thread path did.
*/
private void refreshGitStatus(H)(ref WorkspaceTui w, ref H h, string root,
    uint gen) @system
{
    import std.string : strip;
    import sparkles.event_horizon.live : capture;
    import sparkles.event_horizon.proc : ProcessConfig, StdioMode, StdioSpec;
    import sparkles.event_horizon.sched : currentScheduler, onScheduler, Sched;

    if (!onScheduler)
    {
        // Nothing parked us, so there is no ring to spawn on. Delivering a
        // failure is what the thread path did when its worker could not run,
        // and the cache treats it the same way.
        w.tree.git.deliver(gen, false, null, null);
        h.wake();
        return;
    }
    ref Sched sched = currentScheduler();

    ProcessConfig cfg;
    cfg.stdoutSpec = StdioSpec(StdioMode.pipe);
    cfg.stderrSpec = StdioSpec(StdioMode.nullDev);

    bool ok;
    string top, payload;
    auto tl = capture(sched,
        ["git", "-C", root, "rev-parse", "--show-toplevel"], cfg);
    if (!tl.hasError && tl.value.status.ok)
    {
        top = (cast(const(char)[]) tl.value.stdout_[]).strip.idup;
        auto st = capture(sched, ["git", "-C", root, "status",
            "--porcelain", "-z", "--ignored=matching"], cfg);
        if (!st.hasError && st.value.status.ok)
        {
            payload = (cast(const(char)[]) st.value.stdout_[]).idup;
            ok = true;
        }
    }
    w.tree.git.deliver(gen, ok, top, payload);
    h.wake();
}

/// How long the loop waits for input before ticking the live oracle again
/// (~30 Hz — imperceptible for a ~0.6 ms tip answer, idle when no session).
private enum liveTick = 33.msecs;

/// The wait deadline both loop arms compute identically: the lantern
/// panel's remainder (`LTN4`), capped by the live oracle's tick while an
/// oracle runs, capped at 150 ms while a git-status refresh is in flight.
/// An `eventDriven` caller (the async arm with oracle watchers) skips the
/// oracle tick — arriving lines wake it through the channel — and the git
/// cap disappears whenever the cache delivers instead of being polled
/// (`asyncMode`), which is every refresh once the ring drives them.
private Duration waitDeadline(ref WorkspaceTui w, bool eventDriven = false)
    @system
{
    const untilPanel = w.untilLanternShown();
    Duration deadline = (w.liveActive && !eventDriven)
        ? (untilPanel < liveTick ? untilPanel : liveTick)
        : untilPanel;
    if (w.tree.git.refreshing && !w.tree.git.asyncMode
        && deadline > 150.msecs)
        deadline = 150.msecs;
    const untilScroll = w.dock.nextTickIn();
    if (untilScroll < deadline)
        deadline = untilScroll;
    // A searching picker progresses through `pollAll` — synchronously in the
    // degraded mode, via completions otherwise — and neither wakes a loop
    // blocked on input, so cap the wait while one is running (`PIK5`). The
    // preview pane's debounce/dwell/oracle clocks ask for their own wake.
    if (!w.picker.empty && w.picker.get.busy && deadline > 16.msecs)
        deadline = 16.msecs;
    if (!w.picker.empty && w.picker.get.state.active && w.pickerDoc !is null)
    {
        const untilPreview = w.pickerDoc.nextDeadline();
        if (untilPreview < deadline)
            deadline = untilPreview;
    }
    return deadline;
}

/// A deadline expired with no event: apply a finished git snapshot, advance
/// the guide's clock. `true` when the tree changed and a repaint is due.
private bool onWaitExpired(ref WorkspaceTui w, Duration waited) @system
{
    if (w.tree.git.refreshing && w.tree.git.poll())
    {
        w.tree.rebuild();
        return true;
    }
    // The wait expired rather than a key arriving: advance the guide's
    // clock so the panel opens on time.
    w.tickLantern(waited);
    return w.tickDock(waited);
}

version (unittest)
{
    /// A workspace over two files in a temp directory, wired the way the
    /// entry point wires one. Returns the root so the caller can clean up.
    private string fixtureWorkspace(ref WorkspaceTui w, string stem) @system
    {
        import std.file : mkdirRecurse, tempDir, write;
        import std.path : baseName, buildPath;
        import sparkles.syntax : builtinDark, LabelSet;

        static immutable(Theme)[1] themes = [builtinDark];
        static immutable string[1] names = ["dark"];
        const labels = LabelSet.standard();

        const root = buildPath(tempDir(), stem);
        mkdirRecurse(root);
        write(buildPath(root, "alpha.d"), "int alpha;\n");
        write(buildPath(root, "beta.d"), "int beta;\n");

        w.loadDoc = delegate WorkspaceDoc(string path) @system {
            import std.file : readText;

            const src = readText(path);
            return WorkspaceDoc(title: baseName(path), source: src,
                events: [HighlightEvent.sourceSpan(0, src.length)]);
        };
        w.liveTypes = false; // no oracle subprocess in a test
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
        // Visibility is NOT set here: `arrange` rebuilds the dock layout from
        // scratch, so anything decided before it is overwritten. Callers read
        // the post-arrange value and assert against that.
        w.tree.rebuild();
        w.arrange(80, 24);
        w.openDoc(buildPath(root, "alpha.d"));
        return root;
    }
}


// The loop this module has always run has never been testable: it needs a
// terminal in raw mode, and its two arms are private functions around a
// blocking read. The component contract is what removes that — the same
// `view`/`handle` a live arm drives, driven here by a scripted recorder
// instead (`TST1`), which is the oracle `P2.B5`'s restructuring needs and did
// not otherwise have.
@("workspace.component.recordsWhatAFrameDecided")
@system
unittest
{
    import std.file : rmdirRecurse;
    import sparkles.input : charEvent;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.run_app : isAppFor, runAppRecorded;
    import sparkles.ui_app.record : RecordingHost;

    static assert(isAppFor!(WorkspaceTui, RecordingHost),
        "the workspace must satisfy the component contract the host is"
        ~ " written against — that is what lets a scripted run drive it");

    WorkspaceTui w;
    const root = fixtureWorkspace(w, "hue-workspace-component-test");
    scope (exit) rmdirRecurse(root);

    const treeWas = w.treeVisible;

    RunConfig cfg;
    auto rec = runAppRecorded(w, cfg,
        [
            charEvent('e'), // toggle the explorer (focus follows)
            charEvent('j'), // …and a key the pane it focused owns
        ],
        (ref RecordingHost h) { h.size = Size(80, 24); });

    // One frame before any input, then one per event.
    assert(rec.frames.length == 3);

    // The first frame draws (nothing has been painted yet), and so does every
    // frame an event reached: a keystroke is a reason to repaint by
    // construction, which is `HST9`'s default-draw half.
    assert(!rec.frames[0].skipped);
    assert(!rec.frames[1].skipped && !rec.frames[2].skipped);

    // The global key reached the workspace through the component, not through
    // a pane — and the run mutated the caller's workspace, which is what makes
    // a scripted session an assertion about the real thing.
    assert(w.treeVisible == !treeWas, "'e' toggled the explorer");
    assert(w.treeFocused == w.treeVisible, "and focus followed it");
    assert(!rec.quitRequested, "'e' is not a quit");
}

@("workspace.leaderETogglesTheExplorer")
@system
unittest
{
    import std.file : rmdirRecurse;

    WorkspaceTui w;
    const root = fixtureWorkspace(w, "hue-ws-leader-e");
    scope (exit) rmdirRecurse(root);

    // `<leader>e` lives in the focused pane's own lantern; the workspace must
    // not steal the sequence's tail. (The old hand-rolled 'e' interception
    // consumed the second key and left the leader pending — the sequence
    // never worked in the terminal workspace.)
    const was = w.treeVisible;
    assert(w.handle(Event(KeyEvent(key: Key.char_, ch: ' '))));
    assert(w.handle(Event(KeyEvent(key: Key.char_, ch: 'e'))));
    assert(w.treeVisible == !was, "<leader>e toggled the explorer");
    assert(w.treeFocused == w.treeVisible, "focus follows the pane");

    // …and plain `e` still toggles, now through the pane's intent flag
    // rather than a workspace key switch.
    assert(w.handle(Event(KeyEvent(key: Key.char_, ch: 'e'))));
    assert(w.treeVisible == was);
}

@("workspace.component.anIdlePassDeclinesToDraw")
@system
unittest
{
    import std.file : rmdirRecurse;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.run_app : runAppRecorded;
    import sparkles.ui_app.record : RecordingHost;

    // The property the terminal arm's byte cost depends on: a pass that no
    // event reached and that changed nothing declines the frame, so an
    // untouched document emits nothing at all. The recorder delivers a frame
    // per event, so an empty script IS the idle case — one first frame that
    // draws, and a `requestFrame`-free run that stops there.
    WorkspaceTui w;
    const root = fixtureWorkspace(w, "hue-workspace-idle-test");
    scope (exit) rmdirRecurse(root);

    RunConfig cfg;
    auto rec = runAppRecorded(w, cfg, null,
        (ref RecordingHost h) { h.size = Size(80, 24); });

    assert(rec.frames.length == 1);
    assert(!rec.frames[0].skipped, "the first frame has never been drawn");
    assert(!rec.frames[0].requested,
        "the workspace waits for input; it does not spin");

    // A second pass with no event between it and the first: nothing changed,
    // so nothing is drawn. This is the `dirty` flag the loop arms carried,
    // now expressed as `skipFrame` (`HST9`).
    auto again = runAppRecorded(w, cfg, null,
        (ref RecordingHost h) { h.size = Size(80, 24); });
    assert(again.frames.length == 1 && again.frames[0].skipped,
        "an idle pass over an unchanged document draws nothing");
}

@("workspace.component.outOfBandWorkBecomesHostErrands")
@system
unittest
{
    import std.file : rmdirRecurse;
    import sparkles.input : PointerAction, PointerEvent;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.run_app : runAppRecorded;
    import sparkles.ui_app.record : RecordingHost;

    // The pointer shape used to be a string of hand-rolled OSC 22 the loop
    // wrote out of band; it is an errand now, so what the workspace asks for
    // is assertable without a terminal to read the bytes back from — and a
    // window, which spells the same intent through the window system, gets
    // it for free.
    WorkspaceTui w;
    const root = fixtureWorkspace(w, "hue-workspace-errand-test");
    scope (exit) rmdirRecurse(root);
    if (!w.treeVisible)
        return; // no divider to hover; the arrangement decides that

    // The divider column is the one just past the tree pane — the same one
    // the OSC 22 test hovers.
    const divider = w.dock.dividers[0].rect.x;

    RunConfig cfg;
    auto rec = runAppRecorded(w, cfg,
        [
            Event(PointerEvent(action: PointerAction.move,
                pos: Point(divider, 4))),
            Event(PointerEvent(action: PointerAction.move,
                pos: Point(divider + 8, 4))),
        ],
        (ref RecordingHost h) { h.size = Size(80, 24); });

    assert(rec.frames.length == 3);
    assert(rec.shapes.length >= 1,
        "hovering the divider asked the host for a resize pointer");
    assert(rec.shapes[0] == PointerShape.ewResize);
    assert(rec.outOfBand.length == 0,
        "and asked for it as an errand, not as bytes for one target");
}

@("workspace.component.quitEndsTheRun")
@system
unittest
{
    import std.file : rmdirRecurse;
    import sparkles.input : charEvent;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.run_app : runAppRecorded;
    import sparkles.ui_app.record : RecordingHost;

    // `handle`'s `false` used to break the arm's loop; a component says so
    // through the host, which is what lets the same decision end a run on
    // either target.
    WorkspaceTui w;
    const root = fixtureWorkspace(w, "hue-workspace-quit-test");
    scope (exit) rmdirRecurse(root);

    const treeWas = w.treeVisible;

    RunConfig cfg;
    auto rec = runAppRecorded(w, cfg,
        [charEvent('q'), charEvent('e')],
        (ref RecordingHost h) { h.size = Size(80, 24); });

    assert(rec.quitRequested);
    assert(rec.frames.length == 2, "the frame the quit happened in is recorded");
    assert(w.treeVisible == treeWas, "the 'e' after the quit never arrived");

    // …and it is recorded as DECLINED. The old loop broke on `handle`'s
    // `false` and never reached its paint; a component is asked to present
    // first, so it has to say no. Not theoretical: before this, a real
    // terminal session got one more synchronized-update bracket on the way
    // out, which is how the pty smoke test caught it.
    assert(rec.frames[1].skipped, "a frame after the quit is one nobody sees");
    assert(rec.drawnFrames == 1);
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
    const divider = w.dock.dividers[0].rect.x;
    assert(g[cast(ushort) divider, 3].grapheme == "│", "divider column");
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
    assert(w.dock.paneExtent(WorkspaceTui.treePane) == 32, "the default split");

    // Grab the divider column, drag right by 6, release (STM8).
    const div = w.dock.dividers[0].rect.x;
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(div, 4)))));
    assert(w.dock.resizing);
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(div + 6, 4)))));
    assert(w.dock.paneExtent(WorkspaceTui.treePane) == 38, "the pane followed the drag");
    assert(w.viewer.originX == 39, "the viewer moved with the divider");
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(div + 6, 4)))));
    assert(!w.dock.resizing && w.dock.paneExtent(WorkspaceTui.treePane) == 38);

    // The drag clamps: far left pins at the minimum, far right at half.
    w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(38, 4))));
    w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(0, 4))));
    assert(w.dock.paneExtent(WorkspaceTui.treePane) == 12, "clamped at the minimum");
    w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(99, 4))));
    assert(w.dock.paneExtent(WorkspaceTui.treePane) == 50, "clamped at half the screen");
    w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(99, 4))));
}

@("workspace.leaderFfMountsThePicker")
@system
unittest
{
    import core.thread : Thread;
    import std.algorithm.searching : canFind;
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    WorkspaceTui w;
    const root = fixtureWorkspace(w, "hue-ws-picker-test");
    scope (exit) rmdirRecurse(root);
    scope (exit) if (!w.picker.empty) w.picker.get.shutdown();

    // Long enough that the preview pane can actually scroll (the forwarded-
    // key check below moves its viewport).
    {
        import std.file : write;

        string src;
        foreach (i; 0 .. 40)
            src ~= "int line;\n";
        write(buildPath(root, "alpha.d"), src);
        write(buildPath(root, "beta.d"), src);
    }

    static void settle(ref WorkspaceTui w) @system
    {
        foreach (_; 0 .. 100_000)
        {
            cast(void) w.pollAll();
            if (!w.picker.get.busy)
                return;
            Thread.yield();
        }
    }

    // `<leader>ff` routes through the focused pane's own key path (the one
    // table) and surfaces as the workspace's picker.
    foreach (ch; " ff")
        assert(w.handle(Event(KeyEvent(key: Key.char_, ch: ch))));
    assert(!w.picker.empty && w.picker.get.state.active, "the picker opened");
    // Deterministic preview in a test: no debounce, no oracle subprocess.
    w.pickerDoc.loadDelay = Duration.zero;
    w.pickerDoc.liveOverlays = false;
    settle(w);
    assert(w.picker.get.state.error.code == 0);
    assert(w.picker.get.state.rowCount == 2, "the empty prompt ranks the corpus");
    cast(void) w.pollAll(); // the zero debounce loads the selection now

    // The panel paints over the panes through the shared widget tree, and
    // the preview hole holds a REAL document pane fed by the same loader.
    Grid g;
    g.resize(80, 24);
    w.paint(g);
    string all;
    foreach (y; 0 .. g.rows)
        foreach (x; 0 .. g.cols)
            all ~= g[cast(ushort) x, cast(ushort) y].grapheme;
    assert(all.canFind("›"), "the prompt row is on screen");
    assert(all.canFind("alpha.d"), "the ranked rows are on screen");
    assert(all.canFind(" Files "), "the heading is embedded in the border");
    assert(all.canFind("╭") && all.canFind("╯"), "rounded box corners");
    assert(all.canFind("int "), "the preview pane shows the document itself");

    // `Tab`·`Tab` walks the pane focus to the preview (`PKL7`), and a `j`
    // forwarded there scrolls the DOCUMENT — the pane's own keymap applies.
    {
        import keymap : Scope_;

        assert(w.handle(Event(KeyEvent(key: Key.tab))));
        assert(w.picker.get.focus.isFocused(Scope_.pickerList));
        assert(w.handle(Event(KeyEvent(key: Key.tab))));
        assert(w.picker.get.focus.isFocused(Scope_.pickerPreview));
        const before = w.pickerDoc.pane.vm.top;
        assert(w.handle(Event(KeyEvent(key: Key.char_, ch: 'j'))));
        assert(w.pickerDoc.pane.vm.top == before + 1,
            "a forwarded j scrolls the preview document");
        // The focused preview panel carries the accent chrome; back to the
        // prompt for the typing below.
        assert(w.handle(Event(KeyEvent(key: Key.tab))));
        assert(w.picker.get.focus.isFocused(Scope_.pickerInput));
    }

    // The wheel scrolls the element under the cursor (`DCK7` inside the
    // modal), never a pane beneath the overlay: over the preview hole it
    // scrolls the DOCUMENT, over the list it moves the selection.
    {
        import picker_view : pickerPreviewRect;
        import sparkles.ui.geometry : Constraints;
        import sparkles.ui.layout : layout;

        const geometry = w.pickerGeometry();
        const pkX = (w.width - 2 * geometry.panelCols) / 2;
        const ox = pkX > 0 ? pkX : 0;
        auto view = w.picker.get.buildView(geometry);
        auto frames = layout(view, Constraints(maxW: 2 * geometry.panelCols));
        const hole = pickerPreviewRect(view, frames);

        const before = w.pickerDoc.pane.vm.top;
        assert(w.handle(Event(WheelEvent(dy: 2,
            pos: Point(ox + hole.x + 2, 1 + hole.y + 2)))));
        assert(w.pickerDoc.pane.vm.top == before + 2,
            "wheel over the preview scrolls the document");

        const sel = w.picker.get.state.selection;
        assert(w.handle(Event(WheelEvent(dy: 1, pos: Point(ox + 3, 4)))));
        assert(w.picker.get.state.selection == sel + 1,
            "wheel over the list moves the selection");
        assert(w.handle(Event(KeyEvent(key: Key.up)))); // back for the typing

        // The focus bands are PAINTED, not just declared: with the prompt
        // focused, its row's background differs from an idle row's, and the
        // selected row carries its tint.
        {
            import sparkles.ui.style : Slot;
            import sparkles.ui.widget : WidgetKind;

            auto view2 = w.picker.get.buildView(geometry);
            auto frames2 = layout(view2,
                Constraints(maxW: 2 * geometry.panelCols));
            Rect promptRect;
            foreach (i, ref node; view2.nodes)
                if (node.kind == WidgetKind.row
                    && node.slot == Slot.chromeFocused)
                    promptRect = frames2[i].rect;
            assert(promptRect.width > 0, "the focused prompt declares a band");

            Grid g2;
            g2.resize(80, 24);
            w.paint(g2);
            const bandX = cast(ushort)(ox + promptRect.x + 1);
            const promptBg = g2[bandX,
                cast(ushort)(1 + promptRect.y)].style.bg;
            const selectedBg = g2[bandX,
                cast(ushort)(1 + promptRect.y + 1)].style.bg;
            const idleBg = g2[bandX,
                cast(ushort)(1 + promptRect.y + 2)].style.bg;
            assert(promptBg != idleBg, "the prompt's band is painted");
            assert(selectedBg != idleBg, "…and the selection's tint");
            assert(promptBg != selectedBg, "…and the two are distinct");
        }
    }

    // Typing narrows; Enter opens the accepted file in the viewer pane.
    foreach (ch; "beta")
        assert(w.handle(Event(KeyEvent(key: Key.char_, ch: ch))));
    settle(w);
    assert(w.picker.get.state.rowCount == 1);
    assert(w.handle(Event(KeyEvent(key: Key.enter))));
    assert(!w.picker.get.state.active, "accepting closes the picker");
    assert(w.currentDocPath == buildPath(root, "beta.d"),
        "the accepted file is the open document");
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
    const treeBar = w.dock.scrollFrameOf(WorkspaceTui.treePane).vTrack;
    const sbCol = treeBar.x;
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(sbCol, 2)))));
    assert(w.dock.scrollOf(WorkspaceTui.treePane).v.dragging);
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(60, 6)))));
    assert(w.dock.scrollOf(WorkspaceTui.treePane).v.dragging,
        "the tree kept the grab across the divider");
    assert(!w.viewer.selection.active, "no text selection from a tree-owned drag");
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(60, 6)))));
    assert(!w.dock.scrollOf(WorkspaceTui.treePane).v.dragging);

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
    const div = w.dock.dividers[0].rect.x;
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(div, 4)))));
    PointerShape shape;
    assert(w.takeCursorShape(shape) && shape == PointerShape.ewResize);
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(div, 6)))));
    assert(!w.takeCursorShape(shape), "no transition, no errand");
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(60, 6)))));
    assert(w.takeCursorShape(shape) && shape == PointerShape.default_);

    // The viewer's scrollbar column hovers as ns-resize (vertical), and a
    // grab HOLDS the shape wherever the drag strays — no revert mid-drag.
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(99, 4)))));
    assert(w.takeCursorShape(shape) && shape == PointerShape.nsResize);
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(99, 4)))));
    assert(w.dock.scrollOf(WorkspaceTui.docPane).v.dragging);
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(60, 6)))));
    // Mid-grab drags RE-ASSERT the held shape (never default): terminals /
    // multiplexers may reset the pointer on drag start, so the idempotent
    // re-set keeps the resize shape pinned.
    assert(w.takeCursorShape(shape) && shape == PointerShape.nsResize,
        "the grab re-asserts its shape through the stray drag");
    assert(w.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(60, 6)))));
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(60, 6)))));
    assert(w.takeCursorShape(shape) && shape == PointerShape.default_);

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

@("workspace.selection.edgeAutoscrollExtendsWithoutPointerMotion")
@system unittest
{
    import std.file : rmdirRecurse;
    import gui_preview : PreviewModel;

    WorkspaceTui w;
    const root = fixtureWorkspace(w, "hue-workspace-autoscroll-test");
    scope (exit) rmdirRecurse(root);

    string src;
    foreach (i; 0 .. 80)
        src ~= "int line;\n";
    w.viewer.setDocument("long.d", src,
        [HighlightEvent.sourceSpan(0, src.length)], PreviewModel.init,
        false, TwoslashReturn.init, "d");
    w.arrange(80, 12);

    const body = w.dock.scrollFrameOf(WorkspaceTui.docPane).content;
    const edge = Point(body.x + 5, body.bottom - 2);
    assert(w.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: edge))));
    const before = w.viewer.selection;
    assert(before.active && w.dock.nextTickIn() != Duration.max);

    assert(w.tickDock(16.msecs), "the edge tick emitted a synthetic drag");
    assert(w.viewer.vm.top > 0, "the content advanced under the held pointer");
    assert(w.viewer.selection.hi > before.hi,
        "the unchanged pointer extended over the newly revealed row");

    w.handle(Event(PointerEvent(action: PointerAction.release,
        button: PointerButton.left, pos: edge)));
    assert(w.dock.nextTickIn() == Duration.max,
        "release makes the terminal idle again");
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

@("workspace.diffTypes.bothSidesAnchorThroughTheRealOracle")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    import document : DocumentPipeline;
    import live_types : liveTypesBinary;
    import sparkles.syntax : builtinDark, GrammarRegistry, LabelSet,
        resolveTheme;
    import sparkles.syntax.ts.injection : TsConfigCache;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.ui.style : Slot;

    // `T0`'s acceptance: two `.d` files on disk, one analyzer per side, both
    // payloads anchoring onto their own side's rows. Env-gated exactly like
    // the live-types oracle test — a machine without the extractor skips.
    if (!liveTypesBinary().length)
        skipTest("no twoslash-extract (set $SPARKLES_TWOSLASH_EXTRACT)");
    import std.process : environment;
    if (!environment.get("SPARKLES_DMD_IMPORT_PATH", "").length)
        skipTest("SPARKLES_DMD_IMPORT_PATH not set (enter `nix develop`)");

    const dir = buildPath(tempDir(), "hue-diff-types-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    const oldPath = buildPath(dir, "old.d");
    const newPath = buildPath(dir, "new.d");
    write(oldPath, "module s;\n\nint compute(int a)\n{\n    return a;\n}\n");
    write(newPath, "module s;\n\nlong compute(int a)\n{\n    return a;\n}\n");

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    const labels = LabelSet.standard();

    // A real registry + cache: `loadDiffPair` highlights, and a
    // default-constructed registry has no grammar table to consult.
    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, labels);
    auto pipeline = DocumentPipeline(registry: &registry, cache: &cache);
    auto doc = pipeline.loadDiffPair(oldPath, newPath);
    assert(doc.diffDoc.files.length == 1);

    WorkspaceTui w;
    w.tree.root = dir;
    w.tree.themeValue = &themes[0];
    w.tree.theme = resolveTheme(themes[0], labels);
    w.viewer.names = names[];
    w.viewer.themes = themes[];
    w.viewer.labels = labels;
    w.arrange(80, 24);
    w.viewer.setDocument(doc.title, doc.source, doc.events, doc.preview,
        startPreview: true, doc.twoslash, doc.lang, doc.diffDoc,
        doc.diffSides, doc.diffSession);
    w.startDiffTypes();
    scope (exit) w.stopDiffTypes();

    // A real analysis is seconds, not milliseconds: poll the way the loop
    // does, and skip rather than fail on a slow machine.
    bool bothLive()
        => w.viewer.vm.diffTypes.length == 1
            && w.viewer.vm.diffTypes[0].old_.live
            && w.viewer.vm.diffTypes[0].new_.live;

    foreach (_; 0 .. 120 * 100)
    {
        w.pollDiffTypes();
        if (bothLive())
            break;
        Thread.sleep(10.msecs);
    }
    if (!bothLive())
        skipTest("the oracles did not both answer within 120 s");

    // Both payloads anchored, so both sides' rows carry hover underlines —
    // the property `T0` exists to prove.
    size_t underlines;
    foreach (ref n; w.viewer.vm.tree.nodes)
        if (n.slot == Slot.hoverUnderline)
            ++underlines;
    assert(underlines > 0, "an anchored overlay decorates the diff rows");
}

@("workspace.inspectorPane.toggleSyncsAndCloses")
@system
unittest
{
    import std.process : environment;
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet, Theme;
    import sparkles.syntax.ts.injection : TsConfigCache;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;
    import gui_preview : PreviewModel;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    static GrammarRegistry registry;
    registry = GrammarRegistry.fromEnvironment();
    static TsConfigCache* cache;
    cache = new TsConfigCache;
    *cache = TsConfigCache.create(&registry, LabelSet.standard());

    static immutable string[1] names = ["dark"];
    static immutable Theme[1] themes = [builtinDark];

    WorkspaceTui w;
    w.viewer.names = names[];
    w.viewer.themes = themes[];
    w.viewer.labels = LabelSet.standard();
    w.viewer.vm.cache = cache;
    w.arrange(100, 20);
    w.treeVisible = false;
    w.arrange(100, 20);

    const src = "{\"a\": [1, true]}\n";
    w.viewer.setDocument("t.json", src,
        [HighlightEvent.sourceSpan(0, src.length)], PreviewModel.init,
        false, TwoslashReturn.init, "json");

    // The toggle shows the pane, arranges it a frame, builds the CST tree,
    // seeds the selection from the top visible row, and tints its extent.
    assert(!w.inspVisible);
    w.toggleInspector();
    assert(w.inspVisible);
    assert(w.insp.tv.width >= 20, "the pane got its dock frame");
    assert(w.insp.ci.data.nodes.length >= 5, "the CST tree is built");
    size_t s, e;
    assert(w.insp.selectedExtent(s, e), "the seed selected a node");
    assert(w.viewer.vm.inspectRects.length >= 1, "the extent tint landed");

    // The document pane narrowed to make room.
    assert(w.viewer.originX == 0, "no tree: the viewer starts at 0");

    // The picker (DevTools' semantics) is OFF on open: the panel starts
    // one-way, so hovering the document leaves the selection alone.
    assert(!w.insp.picking);
    const seeded = w.insp.tv.selectedNode;
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(w.viewer.originX + 6, 1)))));
    assert(w.insp.tv.selectedNode == seeded, "no hover sync until it is armed");

    // Arming it (the `⌕` chip's key, `s`) makes a hover walk the tree…
    w.insp.pick(true);
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(w.viewer.originX + 6, 1)))));
    assert(w.insp.lastSyncOffset != size_t.max, "the hover synced");

    // …and a left click in the document disarms it: the reader has chosen.
    assert(w.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left,
        pos: Point(w.viewer.originX + 8, 1)))));
    assert(!w.insp.picking, "a document click pins the node and ends the mode");
    const pinned = w.insp.tv.selectedNode;
    assert(w.handle(Event(PointerEvent(action: PointerAction.move,
        pos: Point(w.viewer.originX + 2, 1)))));
    assert(w.insp.tv.selectedNode == pinned, "…and later hovers leave it");

    // Closing clears the tint, disarms the picker, and returns the space.
    w.insp.pick(true);
    w.toggleInspector();
    assert(!w.inspVisible);
    assert(!w.insp.picking, "sync ends with the panel");
    assert(w.viewer.vm.inspectRects.length == 0, "the tint cleared");
}

@("workspace.inspectorPane.itsScrollbarIsItsOwnColumnAndItHolds")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.process : environment;
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet, Theme;
    import sparkles.syntax.ts.injection : TsConfigCache;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;
    import gui_preview : PreviewModel;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    static GrammarRegistry registry;
    registry = GrammarRegistry.fromEnvironment();
    static TsConfigCache* cache;
    cache = new TsConfigCache;
    *cache = TsConfigCache.create(&registry, LabelSet.standard());

    static immutable string[1] names = ["dark"];
    static immutable Theme[1] themes = [builtinDark];

    WorkspaceTui w;
    w.viewer.names = names[];
    w.viewer.themes = themes[];
    w.viewer.labels = LabelSet.standard();
    w.viewer.vm.cache = cache;
    w.treeVisible = false;
    w.arrange(100, 16);

    const src = "{\"a\": [1, 2, 3, 4, 5, 6, 7, 8], \"b\": {\"c\": true}}\n";
    w.viewer.setDocument("t.json", src,
        [HighlightEvent.sourceSpan(0, src.length)], PreviewModel.init,
        false, TwoslashReturn.init, "json");
    w.toggleInspector();
    assert(cast(long) w.insp.tv.rows.length > w.insp.tv.bodyRows,
        "the tree overflows its pane");

    Grid g;
    g.resize(100, 16);
    w.paint(g);

    // UAT: the two bars must not share a column. The panel's lives in the
    // LAST column of its own pane; the document's in the last column of its.
    string col(ushort x)
    {
        string s;
        foreach (y; 0 .. g.rows)
            s ~= g[x, cast(ushort) y].grapheme;
        return s;
    }

    const inspLast = cast(ushort)(g.cols - 1); // the panel is the rightmost pane
    assert(col(inspLast).canFind("█") || col(inspLast).canFind("░"),
        "the panel's bar paints in its own last column: " ~ col(inspLast));

    // …and a press on that column scrolls the panel and STAYS scrolled once
    // the next frame has painted (the cursor-following re-clamp used to undo
    // it, which is why the bar looked inert). The bar spans the tree window:
    // header, rule, then `bodyRows` rows — the paint above sized it.
    const barBottom = w.dock.scrollFrameOf(WorkspaceTui.inspPane).vTrack.bottom - 1;
    assert(w.handle(Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: Point(inspLast, barBottom)))));
    const grabbed = w.dock.offsetV(WorkspaceTui.inspPane);
    assert(grabbed > 0, "the track press jumped the view");
    w.paint(g);
    assert(w.dock.offsetV(WorkspaceTui.inspPane) == grabbed,
        "the frame did not scroll it back");
}

@("workspace.reloadCurrent.preservesTheViewportAndRefreshesTheInspector")
@system
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet, Theme;
    import sparkles.syntax.ts.injection : TsConfigCache;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    static GrammarRegistry registry;
    registry = GrammarRegistry.fromEnvironment();
    static TsConfigCache* cache;
    cache = new TsConfigCache;
    *cache = TsConfigCache.create(&registry, LabelSet.standard());

    const root = buildPath(tempDir(), "hue-ws-reload-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    const doc = buildPath(root, "d.json");
    write(doc, "{\"a\": [1,\n2,\n3,\n4,\n5,\n6,\n7,\n8]}\n");

    static immutable string[1] names = ["dark"];
    static immutable Theme[1] themes = [builtinDark];

    WorkspaceTui w;
    w.loadDoc = delegate WorkspaceDoc(string path) @system {
        import std.file : readText;
        import std.path : baseName;

        const src = readText(path);
        return WorkspaceDoc(title: baseName(path), source: src, lang: "json",
            events: [HighlightEvent.sourceSpan(0, src.length)]);
    };
    w.viewer.names = names[];
    w.viewer.themes = themes[];
    w.viewer.labels = LabelSet.standard();
    w.viewer.vm.cache = cache;
    w.tree.themeValue = &themes[0];
    w.arrange(90, 8); // a short pane, so the document overflows it
    w.treeVisible = false;
    w.arrange(90, 8);

    (cast(void delegate(string) @system) &w.openDoc)(doc);
    assert(w.currentDocPath == doc);
    w.toggleInspector();
    const nodesBefore = w.insp.ci.data.nodes.length;
    assert(nodesBefore > 0);
    // Scrolled somewhere real, after the toggle's own seed/scroll-follow.
    w.viewer.vm.top = 3;

    // The file changes on disk; the (watch-triggered) reload re-reads it,
    // keeps the viewport, and rebuilds the inspector against the new parse.
    write(doc, "{\"a\": [1,\n2,\n3,\n4,\n5,\n6,\n7,\n8],\n\"b\": true}\n");
    w.reloadPending = true; // what the watch fiber would set
    w.reloadPending = false;
    w.reloadCurrent();

    import std.algorithm.searching : canFind;

    assert(w.viewer.vm.source.canFind("\"b\": true"), "the reload re-read");
    assert(w.viewer.vm.top == 3, "the viewport survived the reload");
    assert(w.insp.ci.data.nodes.length > nodesBefore,
        "the inspector rebuilt against the new parse");
    assert(w.viewer.vm.inspectRects.length == 0,
        "the stale extent tint cleared; the next hover re-syncs");
}

@("workspace.arrange.resizeKeepsTheFirstVisibleLine")
@system
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;

    // Issue #299 through the whole terminal workspace, not just the pane:
    // `arrange` re-lays the panes out AND round-trips every offset through
    // the dock's own clamp, which is the second place a resize could move
    // the reader.
    const root = buildPath(tempDir(), "hue-workspace-resize-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    string src;
    foreach (i; 0 .. 40)
        src ~= "line of source number that is long enough to wrap somewhere\n";
    write(buildPath(root, "long.d"), src);

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    const labels = LabelSet.standard();

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
    w.tree.theme = resolveTheme(themes[0], labels);
    w.pageFg = w.tree.pageFg = toRgb(w.tree.theme.defaults.fg,
        RgbColor(0xcc, 0xcc, 0xcc));
    w.pageBg = w.tree.pageBg = toRgb(w.tree.theme.defaults.bg,
        RgbColor(0x1e, 0x1e, 0x1e));
    w.viewer.names = names[];
    w.viewer.themes = themes[];
    w.viewer.labels = labels;
    w.tree.rebuild();
    w.arrange(100, 20);
    w.openDoc(buildPath(root, "long.d"));

    // Through the container, so the offset is the one the dock agrees with
    // (it clamps to the pane, exactly as a real session would).
    w.viewer.vm.scrollTo(12);
    w.commitPaneScrolls();
    const anchor = w.viewer.vm.rows[cast(size_t) w.viewer.vm.top].srcStart;
    assert(anchor != size_t.max && w.viewer.vm.top > 0);

    w.arrange(50, 20); // narrower: the document re-wraps
    assert(w.viewer.vm.rows[cast(size_t) w.viewer.vm.top].srcStart == anchor,
        "a narrower workspace moved the first visible line");

    w.arrange(50, 200); // taller than the whole document
    assert(w.viewer.vm.rows[cast(size_t) w.viewer.vm.top].srcStart == anchor,
        "a taller workspace scrolled the document up to fill itself");
}
