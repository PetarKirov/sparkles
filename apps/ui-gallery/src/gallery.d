/**
The gallery itself: the component `runApp` drives.

$(B `view` and `handle` are member templates over the host type.) One source
serves the recording host, the terminal host and the GPU host — the gallery
names no canvas, no window and no terminal, which is the property the catalog
exists to demonstrate rather than assert.

The shell is a header band, a page list, the page, and a status bar. Everything
interactive in it is a toolkit state machine advanced by transformation, so a
scripted event list run through the recording host reproduces exactly what a
person pressing the same keys would get.
*/
module gallery;

import std.conv : text;

import sparkles.base.term_control : PointerShape;
import sparkles.input : Event, isDismiss, Key, KeyAction, KeyEvent, match,
    PointerAction, PointerEvent, ResizeEvent, WheelEvent;
import sparkles.terminal_view.cell_paint : paintCells;
import sparkles.ui.components.dock : DockAxis, DockContainer, PaneId, RouteKind;
import sparkles.ui.components.chrome : headerBar, scrollView;
import sparkles.ui.geometry : Constraints, Insets, Point, Rect, SizeSpec;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.state : hoverTargets, keyedRects, ScrollState,
    wantedPointerShape;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle, Visual;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.run_app : AppTheme;
import inspector : inspectorActivate, inspectorBody, inspectorInnerWidth;
import keymap : acceptsTyped, bindingsAt, Binding, Chord, commandFor,
    GalleryCommand, GalleryContext, GalleryScope, normaliseGrabKey, ShiftReq,
    terminalGrabPolicy;
import kit;
import pages.split_page : splitMax = maxPane, splitMin = minPane;
import pages.terminal_page : hitPane, paneHeight, terminalOwns = ownsId;
import registry : pages, stepPage, terminalPageIndex;
import scrollbars;
import state;
import term_store : TerminalStore;

// No module-level `@safe:` here, deliberately. `view` and `handle` are member
// templates instantiated against every host, and the GPU host's `size` and
// `frameSeconds` are `@system` — forcing `@safe` on the templates would reject
// the very backend the gallery exists to run on. The attributes infer, exactly
// as they do for `isCanvas` and `isHost`; the pure view helpers below, being
// non-templates, are annotated by hand.
//
// The theme accessor is `@safe` because `runApp` probes for it from a context
// that may be either.

// The capture-release chords and the scrollback pass-through are the grab
// policy's data (`terminalGrabPolicy` in `keymap`), routed through
// `sparkles.ui.focus.checkGrab` — not a hand-written predicate here.

/// A chord's display label, for the status bar and the help overlay. GC
/// strings are fine — the gallery is not a `@nogc` surface, and the label
/// feeds a per-frame widget text.
private string chordText(in Chord c) @safe pure
{
    import std.conv : to;

    string s;
    if (c.ctrl)
        s ~= "ctrl+";
    if (c.alt)
        s ~= "alt+";
    if (c.key == Key.char_)
    {
        dchar shown(dchar ch)
            => c.shift == ShiftReq.yes && ch >= 'a' && ch <= 'z'
                ? cast(dchar)(ch + ('A' - 'a')) : ch;
        if (c.shift == ShiftReq.yes && !(c.ch >= 'a' && c.ch <= 'z'))
            s ~= "shift+";
        s ~= c.ch == ' ' ? "Space" : shown(c.ch).to!string;
        if (c.chEnd)
            s ~= "-" ~ shown(c.chEnd).to!string;
    }
    else
    {
        if (c.shift == ShiftReq.yes)
            s ~= "shift+";
        s ~= namedKey(c.key);
    }
    return s;
}

/// ditto
private string namedKey(Key k) @safe pure nothrow @nogc
{
    switch (k)
    {
        case Key.up: return "↑";
        case Key.down: return "↓";
        case Key.left: return "←";
        case Key.right: return "→";
        case Key.enter: return "⏎";
        case Key.tab: return "Tab";
        case Key.escape: return "Esc";
        case Key.back: return "Back";
        case Key.home: return "Home";
        case Key.end: return "End";
        case Key.pageUp: return "PgUp";
        case Key.pageDown: return "PgDn";
        case Key.backspace: return "⌫";
        default: return "?";
    }
}

/// ditto
struct Gallery
{
    /// Everything the gallery knows.
    GalleryState s;

    /// The Terminal page's live instances — non-copyable, pointer-pinned, so
    /// they cannot live inside the state value. Keyed by tab id.
    TerminalStore store;

    /// Set by `main` for a real run. The recorded tests and `--render` leave
    /// it off, so a scripted `n` raises the request flag without forking a
    /// shell into the test harness.
    bool spawnEnabled;

    /**
    The body band's tiling as a dock (`DCK1`): three panes in one horizontal
    split, so the two seams between them are $(B draggable dividers) rather
    than fixed chrome. The container owns the extents and the drag machine;
    the widget row keeps painting exactly what it painted — the divider IS
    the gap column the row already had — and the shell mirrors the arranged
    widths into `s.navCols`/`s.inspCols` for the pure views.
    */
    DockContainer dock;

    private enum PaneId paneNav = 1;
    private enum PaneId paneContent = 2;
    private enum PaneId paneInsp = 3;

    private bool prevTermFocus;
    private int dbgFrame; // the UIG_SHOT self-verification hook's clock

    /**
    The theme this frame paints in.

    Declaring it is what turns the Themes page from a list of names into a
    browser: `runApp` probes for this member and, finding it, resolves every
    slot on every page against whatever the gallery currently has selected.
    */
    AppTheme theme() const @safe
    {
        const t = s.theme;
        return AppTheme(
            palette: t.effectivePalette,
            pageFg: rgbOr(t.defaultFg, 0xcc, 0xcc, 0xcc),
            pageBg: rgbOr(t.defaultBg, 0x00, 0x00, 0x00),
        );
    }

    /// One frame.
    WidgetTree view(H)(ref H h)
    {
        noteHost(h);

        // The dock arranges the body band before anything reads a width:
        // `contentWidth` is a mirror of what the container tiled, and the
        // page view is about to consume it.
        syncDock();

        // A window paces frames; a terminal wakes on input and reports zero.
        // The toast's own mode follows from that (see `toastConfigFor`).
        static if (__traits(compiles, { float f = h.frameSeconds; }))
            const dtMs = cast(int)(h.frameSeconds * 1000);
        else
            const dtMs = 0;
        s.hasFrameClock = dtMs > 0;
        if (s.toast.visible && s.hasFrameClock)
            s.toast = s.toast.stepped(dtMs, toastConfigFor(true));

        // The shell owns the clock, so a page cannot read one: it is handed the
        // delta and says whether it wants another frame.
        const pageAnimating = stepPage(s, dtMs);

        // The Terminal page's side effects — spawn/close requests, the
        // per-tab pty pump, title and exit mirroring — before the page view
        // reads the state they update. A pure page cannot do any of this.
        syncTerminals(h);

        // `UIG_SHOT=<file>`: the GPU arm's self-verification hook — spawn
        // three shells, run a command, scroll back, screenshot, quit. How
        // this page's pixels get checked from a test script, no human and
        // no display assumptions in the way (the terminal-view component
        // has the same idea in `debugScreenshotAndExit`).
        static if (__traits(compiles, { auto c_ = h.canvas; auto f_ = c_.fonts; }))
        {
            import std.process : environment;

            const shot = environment.get("UIG_SHOT");
            if (shot !is null)
            {
                dbgFrame++;
                if (dbgFrame == 30 || dbgFrame == 40 || dbgFrame == 50)
                    s.terms.spawnRequested = true;
                if (dbgFrame == 80 && s.terms.any)
                    if (auto tv = store.byId(s.terms.tabs[s.terms.active].id))
                        () @trusted {
                            import sparkles.terminal_view.input : pty_write;

                            static immutable cmd = "seq 1 100\r";
                            pty_write(tv.s.pty_fd, cmd.ptr, cmd.length);
                        }();
                if (dbgFrame == 200)
                    scrollTerminal(-30);
                // Through the host: the capture must land between the last draw
                // call and the swap, which only the arm knows. raylib's
                // `TakeScreenshot` called from here wrote a black PNG on macOS.
                static if (__traits(hasMember, H, "screenshot"))
                    if (dbgFrame == 260)
                        (() @trusted {
                            import std.string : toStringz;

                            h.screenshot(shot.toStringz);
                        })();
                if (dbgFrame == 280)
                    h.quit();
            }
        }

        auto b = Builder();

        // The page first, so its natural height is known before the scroll
        // view that clips it is built — one measurement, shared by the
        // viewport, the clamp and the scrollbar, so the three cannot disagree.
        const pageRoot = pages[s.page].view(b, s);
        s.contentRows = measureHeight(b, pageRoot, s.contentWidth);
        const viewport = s.contentHeight;
        dock.contentExtent(paneContent, s.contentWidth, s.contentRows);

        const header = shellHeader(b);

        // The inspector panel, the same shape one band over: build the body,
        // measure it, clamp the machine against the measurement, ease. Built
        // AFTER the page so its dump describes this frame's subject at this
        // frame's width.
        uint inspRoot;
        if (s.inspectorVisible)
        {
            inspRoot = inspectorBody(b, s);
            s.inspectorRows = measureHeight(b, inspRoot,
                inspectorInnerWidth(s));
            dock.contentExtent(paneInsp, inspectorInnerWidth(s),
                s.inspectorRows);
        }
        dock.tickScroll(dtMs / 1000.0f, s.caps);
        const content = contentPane(b, pageRoot, viewport);
        // The bands are pinned to one row each rather than left to fit. On a
        // short terminal the sidebar's natural height exceeds the surface, and
        // a column that has to reclaim the difference takes it from whichever
        // child will give — which was the header, leaving it drawn on top of
        // the page. `grow` on the body is what absorbs the shortfall.
        b.nodes[header].height = SizeSpec.fixed(1);

        // On a narrow surface the list yields its width rather than squeezing
        // the catalog into a third of the screen. `collapsed`, not `hidden`:
        // hidden would keep the 22 cells and give the page nothing.
        uint[] bodyChildren;
        if (s.navVisible)
            bodyChildren ~= navPane(b);
        bodyChildren ~= content;
        if (s.inspectorVisible)
            bodyChildren ~= inspectorPane(b, inspRoot, viewport);

        const body_ = b.add(Widget(
            kind: WidgetKind.row,
            children: bodyChildren,
            gap: s.navVisible || s.inspectorVisible ? 1 : 0,
            height: SizeSpec.grow(),
        ));
        const footer = statusBar(b);
        b.nodes[footer].height = SizeSpec.fixed(1);

        uint root = b.add(Widget(
            kind: WidgetKind.column,
            children: [header, body_, footer],
            width: SizeSpec.grow(),
            height: SizeSpec.grow(),
        ));

        if (s.helpOpen)
            root = b.add(Widget(
                kind: WidgetKind.stack,
                children: [root, helpOverlay(b)],
                width: SizeSpec.grow(),
                height: SizeSpec.grow(),
            ));

        // An animation asks for one more frame at a time, so a finished one
        // stops costing anything without having to remember to turn itself off.
        // …including the scrollbar's width, which is why hovering one is an
        // animation rather than a jump: the frames it asks for are the frames
        // the ease needs.
        if ((s.toast.visible || pageAnimating
                || easing(dock.scrollOf(paneContent), s.caps)
                || easing(s.demoView, s.caps)
                || easing(s.chromeView, s.caps)
                || easing(s.termView, s.caps)
                || easing(dock.scrollOf(paneInsp), s.caps)) && s.hasFrameClock)
            h.requestFrame();

        return b.finish(root);
    }

    /// Remembers the host's coordinate mapping without advancing a frame.
    private void noteHost(H)(ref H h)
    {
        s.surface = h.size;
        s.backend = h.backend;
        s.caps = h.capabilities;
        s.guiCellW = 0;
        s.guiCellH = 0;
        static if (__traits(compiles, {
                int cw_ = h.canvas.cellW;
                int ch_ = h.canvas.cellH;
            }))
            if (s.backend == Backend.gui)
            {
                s.guiCellW = h.canvas.cellW;
                s.guiCellH = h.canvas.cellH;
            }
        dock.cellW = s.guiCellW > 0 ? s.guiCellW : 1;
        dock.cellH = s.guiCellH > 0 ? s.guiCellH : 1;
    }

    /// One event.
    void handle(H)(ref H h, in Event e)
    {
        e.match!(
            (in KeyEvent k) { onKey(h, k); },
            (in PointerEvent p) { onPointer(h, p); },
            (in WheelEvent w) { onWheel(h, w); },
            (in ResizeEvent r) { s.surface = r.size; },
            (in _) {},
        );
    }

    /**
    The draw phase (`HST13`): the Terminal page's live pane, painted into the
    rect this same frame's layout gave its keyed box — `TVW7`'s whole point.
    Every other page paints nothing here and costs nothing.
    */
    void paint(H)(ref H h, in WidgetTree tree, in Frame[] frames)
    {
        if (s.page != terminalPageIndex || !s.terms.any)
            return;
        auto tv = store.byId(s.terms.tabs[s.terms.active].id);
        if (tv is null)
            return;
        foreach (kr; keyedRects(tree, frames))
            if (kr.key == keyTermPane)
            {
                // The pane box is borderless — the group's border wraps it
                // and the bar together — so the keyed rect IS the cell grid.
                const inner = kr.rect;
                if (inner.width <= 0 || inner.height <= 0)
                    return;
                // Next frame's grid follow reads this: layout's rect exists
                // only now, at paint time — the one-frame lag is the design.
                s.terms.paneCols = cast(ushort) inner.width;
                s.terms.paneRows = cast(ushort) inner.height;
                s.terms.paneX = cast(ushort) inner.x;
                s.terms.paneY = cast(ushort) inner.y;
                static if (__traits(compiles, { auto c_ = h.canvas; auto f_ = c_.fonts; }))
                    paintTermChrome(h, tv, inner); // padding fill + pane + rail
                else static if (__traits(compiles, paintCells(tv.s, h.canvas, inner)))
                    // An lvalue canvas (the recorder). The paint is C FFI over
                    // this instance's own live handles, hence the trust.
                    (() @trusted => paintCells(tv.s, h.canvas, inner))();
                else
                {
                    // The canvas is minted per call (the terminal host); it
                    // is a view over the grid, so a copy paints the same cells.
                    auto c = h.canvas;
                    (() @trusted => paintCells(tv.s, c, inner))();
                }
                return;
            }
    }

    // ── keyboard ────────────────────────────────────────────────────────────

    private void onKey(H)(ref H h, in KeyEvent k)
    {
        // The routing chain (`FOC4`, keymap.md): grab → modal/focused scopes
        // (context gating in the one table) → dispatch. With a terminal
        // focused, the shell inside the pane owns the keyboard — `q`, `Tab`,
        // arrows, `Ctrl+C` are $(I its) keys, not the gallery's, and releases
        // forward too (the terminal-grade keyboard encodes them). The
        // release chords and the scrollback pass-through are the grab
        // policy's data, not a hand-written predicate — and the grab is
        // checked before the release-drop below for exactly that reason.
        if (terminalCaptures)
        {
            import sparkles.ui.focus : checkGrab, GrabVerdict, KeyGrab;

            auto grab = KeyGrab(keyTermPane);
            const verdict = k.action == KeyAction.release
                ? GrabVerdict.forward
                : checkGrab(grab, normaliseGrabKey(k), terminalGrabPolicy);
            final switch (verdict)
            {
            case GrabVerdict.released:
                s.terms.focused = false;
                return;
            case GrabVerdict.passthrough:
                // The emulator convention's scrollback keys — the second and
                // last thing the gallery keeps from a focused terminal.
                const page = s.terms.paneRows > 2 ? s.terms.paneRows - 1 : 1;
                return scrollTerminal(k.key == Key.pageUp ? -page : page);
            case GrabVerdict.forward:
                if (auto tv = store.byId(s.terms.tabs[s.terms.active].id))
                    cast(void) (() @trusted => tv.sendKey(k))();
                return;
            case GrabVerdict.none:
                assert(0, "an active capture always has a grab");
            }
        }

        // A release is not a second press. Terminals never send one; a window
        // does, and an app that switched on the key alone would act twice.
        if (k.action == KeyAction.release)
            return;

        // On a target with no frame clock the toast holds until an event ends
        // it — which is this event, before it is acted on, so a key that
        // raises a new toast still raises one.
        if (!s.hasFrameClock && s.toast.visible)
            s.toast = s.toast.dismissed(toastConfigFor(false));

        // The ONE table: the help overlay is a modal scope, the showing
        // page's scope gets first refusal in the content region (which is
        // what lets a tree own the arrow keys without the page list losing
        // them), and the shell's rows sit last.
        const r = commandFor(k, keyContext());
        if (pages[s.page].onCommand !is null
            && pages[s.page].onCommand(s, r.cmd, r.arg))
            return;
        final switch (r.cmd)
        {
            case GalleryCommand.none:
                cast(void) pageDeclinedFromNav(k);
                return;
            case GalleryCommand.quit: return h.quit();
            case GalleryCommand.showHelp: s.helpOpen = true; return;
            case GalleryCommand.helpClose: s.helpOpen = false; return;
            case GalleryCommand.regionToggle:
                s.region = s.region == Region.nav ? Region.content : Region.nav;
                return;
            case GalleryCommand.enterContent:
                s.region = Region.content;
                return;
            case GalleryCommand.moveDown: return moveWithin(1);
            case GalleryCommand.moveUp: return moveWithin(-1);
            case GalleryCommand.pagePrev:
                return setPage(s.page == 0 ? pages.length - 1 : s.page - 1);
            case GalleryCommand.pageNext:
                return setPage((s.page + 1) % pages.length);
            case GalleryCommand.pageJump: return setPage(r.arg - 1);
            case GalleryCommand.scrollPageUp:
                return scrollContent(-(s.contentHeight - 1));
            case GalleryCommand.scrollPageDown:
                return scrollContent(s.contentHeight - 1);
            case GalleryCommand.scrollHome: return scrollContent(-int.max / 4);
            case GalleryCommand.scrollEnd: return scrollContent(int.max / 4);
            case GalleryCommand.themeNext: return cycleTheme(1);
            case GalleryCommand.themePrev: return cycleTheme(-1);
            case GalleryCommand.toggleNavPin:
                s.navPinned = !s.navPinned;
                return;
            case GalleryCommand.toggleInspector:
                s.inspectorOpen = !s.inspectorOpen;
                return;

            // The pages' commands — answered by `onCommand` above, so an arm
            // reached here means the page it belongs to is not showing.
            case GalleryCommand.layoutWidthMode: case GalleryCommand.layoutAlignX:
            case GalleryCommand.layoutAlignY: case GalleryCommand.layoutGap:
            case GalleryCommand.layoutPadding: case GalleryCommand.layoutThird:
            case GalleryCommand.layoutGrow: case GalleryCommand.layoutShrink:
            case GalleryCommand.tracksPreset: case GalleryCommand.tracksGrow:
            case GalleryCommand.tracksShrink:
            case GalleryCommand.textGrow: case GalleryCommand.textShrink:
            case GalleryCommand.textHang:
            case GalleryCommand.compTabPrev: case GalleryCommand.compTabNext:
            case GalleryCommand.compAction: case GalleryCommand.compScrollDown:
            case GalleryCommand.compScrollUp:
            case GalleryCommand.treeDown: case GalleryCommand.treeUp:
            case GalleryCommand.treeExpand: case GalleryCommand.treeCollapse:
            case GalleryCommand.treeActivate: case GalleryCommand.treeOpenAll:
            case GalleryCommand.treeCloseAll:
            case GalleryCommand.tablePreset: case GalleryCommand.tableRowRules:
            case GalleryCommand.tableStubCol:
            case GalleryCommand.tableScrollLeft:
            case GalleryCommand.tableScrollRight:
            case GalleryCommand.tableScrollUp:
            case GalleryCommand.tableScrollDown:
            case GalleryCommand.scrollNext: case GalleryCommand.scrollPrev:
            case GalleryCommand.scrollNextPage: case GalleryCommand.scrollPrevPage:
            case GalleryCommand.scrollTop: case GalleryCommand.scrollBottom:
            case GalleryCommand.machAnchor: case GalleryCommand.machExtend:
            case GalleryCommand.machFocusNext: case GalleryCommand.machFocusPrev:
            case GalleryCommand.machFoldToggle: case GalleryCommand.machFoldPolarity:
            case GalleryCommand.machPulse:
            case GalleryCommand.splitShrink: case GalleryCommand.splitGrow:
            case GalleryCommand.dockShrink: case GalleryCommand.dockGrow:
            case GalleryCommand.dockTabPrev: case GalleryCommand.dockTabNext:
            case GalleryCommand.dockFocusNext: case GalleryCommand.dockWest:
            case GalleryCommand.dockEast: case GalleryCommand.dockNorth:
            case GalleryCommand.dockSouth: case GalleryCommand.dockReset:
            case GalleryCommand.termNew: case GalleryCommand.termClose:
            case GalleryCommand.termPrev: case GalleryCommand.termNext:
            case GalleryCommand.termKeepExited: case GalleryCommand.termFocus:
                return;
        }
    }

    /**
    The nav region's last word: a key the shell does not claim still reaches
    the showing page.

    The region decides the ORDER of refusal, not whether the page is asked at
    all — the page's scope resolves first in the content region (above), and
    here, where the shell's rows have already declined, the same key is
    re-resolved in the page's scope. Without this the status bar's promise is
    one the nav region cannot keep: it lists a page's keys unconditionally,
    so a reader who has not yet discovered `Tab` presses an advertised `f`
    and nothing happens. The shell's rows are still tried first, which is
    what keeps the list's own arrows (and `j`/`k`) on a page that binds them.
    */
    private bool pageDeclinedFromNav(in KeyEvent k) @safe
    {
        if (s.region != Region.nav || pages[s.page].onCommand is null)
            return false;
        const inPage = commandFor(k, GalleryContext(
            pageScope: pages[s.page].scope_, contentRegion: true,
            helpShown: s.helpOpen));
        return inPage.cmd != GalleryCommand.none
            && pages[s.page].onCommand(s, inPage.cmd, inPage.arg);
    }

    /// The resolution context: the showing page's scope, the focused region,
    /// and the help modal.
    private GalleryContext keyContext() const @safe
        => GalleryContext(pageScope: pages[s.page].scope_,
            contentRegion: s.region == Region.content,
            helpShown: s.helpOpen);

    /// Whether the keyboard belongs to the shell inside the pane.
    private bool terminalCaptures() const @safe
        => s.page == terminalPageIndex && s.terms.focused && s.terms.any;

    // ── the dock — the resizable body tiling ────────────────────────────────

    /**
    Builds the three-pane layout once, then per frame: visibility follows the
    shell's own yield rules, the ceilings follow the surface (hue's shape —
    a sidebar sized for a wide window must not keep that width when the
    window shrinks under it), and the arranged widths mirror into the state.
    */
    private void syncDock() @safe
    {
        import sparkles.ui_raylib.raylib_canvas : scrollbarMinExtentPx;

        dock.paintedScrollbarCellW = s.guiCellW;
        dock.paintedScrollbarCellH = s.guiCellH;
        dock.paintedScrollbarMinExtent = s.guiCellH > 0
            ? scrollbarMinExtentPx : 0;
        if (dock.layout.nodes.length == 0)
        {
            const n = dock.layout.addLeaf(paneNav,
                extent: navWidth, minExtent: navMinCols);
            const c = dock.layout.addLeaf(paneContent,
                minExtent: contentMinCols);
            const i = dock.layout.addLeaf(paneInsp,
                extent: inspectorWidth, minExtent: inspMinCols);
            dock.layout.nodes[n].scrollGutterV = gutterCells;
            dock.layout.nodes[c].scrollGutterV = gutterCells;
            dock.layout.nodes[i].scrollGutterV = gutterCells;
            dock.layout.root = dock.layout.addSplit(DockAxis.horizontal,
                [n, c, i]);
        }

        dock.layout.setVisible(paneNav, s.navVisible);
        dock.layout.setVisible(paneInsp, s.inspectorVisible);

        // Ceilings, re-stated per frame so `arrange`'s re-clamp keeps both
        // side panes inside a shrinking window: a third for the list, half
        // for the panel — a dump wants width, a list of titles does not.
        const w = s.surface.width;
        dock.layout.nodes[dock.layout.nodeOf(paneNav)].maxExtent =
            w / 3 > navMinCols ? w / 3 : navMinCols;
        dock.layout.nodes[dock.layout.nodeOf(paneInsp)].maxExtent =
            w / 2 > inspMinCols ? w / 2 : inspMinCols;

        dock.arrange(bodyArea());
        mirrorDock();
        dock.contentExtent(paneNav, dock.paneExtent(paneNav), pages.length);
    }

    /// The rows the body band occupies — under the header, above the footer.
    /// The dock tiles the same rect the widget row is laid out into, which
    /// is the whole reason its divider rects land on the row's gap columns.
    private Rect bodyArea() const @safe
        => Rect(0, 1, s.surface.width, s.contentHeight);

    /// The arranged widths, into the state the pure views read. A hidden
    /// pane's mirror keeps its last value — it comes back at the width it
    /// was dragged to.
    private void mirrorDock() @safe
    {
        if (s.navVisible)
            s.navCols = dock.paneExtent(paneNav);
        if (s.inspectorVisible)
            s.inspCols = dock.paneExtent(paneInsp);
    }

    /**
    After a divider drag: a drag hands its $(B before) node the new extent,
    and the inspector divider's before node is the centre pane — which must
    stay flexible, or the page stops following the window the moment that
    divider is touched. The inspector already took its delta from the same
    drag, so unfixing the centre re-arranges to the identical picture.
    (A dock finding the catalog records — hue never sees it, because its
    flexible pane sits last.)
    */
    private void reflexCentre() @safe
    {
        const c = dock.layout.nodeOf(paneContent);
        if (c != uint.max && dock.layout.nodes[c].extent > 0)
        {
            dock.layout.nodes[c].extent = 0;
            dock.arrange(bodyArea());
        }
        mirrorDock();
    }

    /**
    The GPU arm's terminal chrome, in the one place that may paint pixels —
    the draw phase (`UGL-O6`'s exception):

    $(LIST
        * The group's interior — the layout's border-cell padding included —
            filled in the $(B terminal's own background), inset a couple of
            px so the hairline border stays visible. On this arm the border
            is a stroke, not a cell, so the padding would otherwise read as
            a dead page-colored frame; painted in the terminal's background
            it is window padding, as terminal emulators treat their own.
        * The pane's cells.
        * hue's rail: sub-cell width (⅓ cell idle, 1.5 under the pointer),
            eased by the same machine the cell bar quantizes — but the
            thumb and its grab both resolve on the same pixel track with the
            same 24 px minimum. Ordinary gallery hits are converted back to
            cells after scrollbar routing; the bar keeps the raw coordinate.
    )
    */
    private void paintTermChrome(H, TV)(ref H h, TV tv, in Rect pane)
    {
        import raylib : Color, DrawRectangle;
        import sparkles.ui.canvas : DrawOp, OpKind, RuleEdge;

        auto c = h.canvas;
        const cw = c.fonts.cellW();
        const ch = c.fonts.cellH();

        const bg = tv.background();
        enum strokePx = 2;
        (() @trusted => DrawRectangle(
            (pane.x - 1) * cw + strokePx,
            (pane.y - 1) * ch + strokePx,
            (pane.width + gutterCells + 2) * cw - 2 * strokePx,
            (pane.height + 2) * ch - 2 * strokePx,
            Color(bg.r, bg.g, bg.b, 255)))();

        tv.paintPane(h, pane);

        if (s.terms.sbTotal <= s.terms.sbLen || s.terms.sbLen <= 0)
            return;
        c.scrollbar(DrawOp(
            kind: OpKind.scrollbar,
            rect: Rect(pane.x + pane.width, pane.y, gutterCells, pane.height),
            ruleEdge: RuleEdge.right,
            barContent: cast(int) s.terms.sbTotal,
            barViewport: cast(int) s.terms.sbLen,
            barOffset: cast(int) s.termView.v.offset,
            expandPercent: cast(ubyte) s.termView.vAnim.percent,
            barTrackColor: mixRgb(bg, theme().pageFg, 0.25f),
            visual: Visual(fg: mixRgb(bg, theme().pageFg, 0.55f)),
        ));
    }

    // ── the Terminal page's frame glue ──────────────────────────────────────

    /**
    Everything the Terminal page's pure view cannot do, once per frame:
    consume the spawn/close requests, pump $(B every) live pty (a background
    child otherwise blocks on a full buffer), mirror titles and exits into
    the tab model, apply the exit policy, follow the pane rect, and report
    focus edges (DECSET 1004).
    */
    private void syncTerminals(H)(ref H h)
    {
        if (s.terms.spawnRequested)
        {
            s.terms.spawnRequested = false;
            if (spawnEnabled && !s.terms.full)
                spawnOne(h);
        }
        if (s.terms.closeRequested >= 0)
        {
            const idx = s.terms.closeRequested;
            s.terms.closeRequested = -1;
            if (idx < s.terms.count)
            {
                (() @trusted => store.closeFor(s.terms.tabs[idx].id))();
                s.terms.close(idx);
            }
        }

        for (size_t i = 0; i < s.terms.count;)
        {
            auto tv = store.byId(s.terms.tabs[i].id);
            if (tv is null)
            {
                i++;
                continue;
            }
            () @trusted {
                tv.pump();
                if (tv.takeTitleChanged())
                    s.terms.tabs[i].setLabel(tv.title);
            }();
            if (tv.s.childExited && tv.s.childReaped && !s.terms.tabs[i].exited)
            {
                s.terms.tabs[i].exited = true;
                s.terms.tabs[i].exitStatus = tv.s.childStatus;
                if (i == s.terms.active)
                    s.terms.focused = false; // a dead shell types nowhere
                // VSCode-shaped unless held: a clean exit closes its own tab,
                // a failure stays with the code in the label.
                if (!s.terms.keepExited && tv.s.childStatus == 0)
                {
                    (() @trusted => store.closeFor(s.terms.tabs[i].id))();
                    s.terms.close(i);
                    continue;
                }
            }
            i++;
        }

        // The active pane: the rect the draw phase measured last frame drives
        // the grid, and `decideRedraw` SNAPSHOTS the render state — the
        // painters iterate that snapshot, so a frame that skips it paints an
        // empty screen (a black pane with a parked cursor, as found live).
        // The gallery repaints every frame, so the returned answer is unused;
        // the snapshot is the point.
        if (s.terms.any)
            if (auto tv = store.byId(s.terms.tabs[s.terms.active].id))
                () @trusted {
                    if (s.terms.paneCols > 0 && s.terms.paneRows > 0)
                        tv.resize(s.terms.paneCols, s.terms.paneRows);
                    // The scrollback bar drives a ScrollView machine, but
                    // ghostty owns the real offset — apply the machine's
                    // intent as a viewport delta, then mirror the truth back
                    // into the machine and the page's numbers. Intent is
                    // measured against LAST frame's mirror, so a move ghostty
                    // made itself (wheel, new output re-pinning the bottom)
                    // never reads as a drag. Applied BEFORE the render-state
                    // snapshot below, so the jump paints this frame.
                    if (s.termView.v.offset != s.terms.sbOffset)
                        tv.scrollViewport(cast(int)
                            (s.termView.v.offset - s.terms.sbOffset));
                    cast(void) tv.decideRedraw();
                    const sb = tv.scrollback();
                    s.terms.sbTotal = sb.total;
                    s.terms.sbLen = sb.len;
                    s.terms.sbOffset = sb.offset;
                    s.termView.v = s.termView.v.scrolledTo(cast(int) sb.offset);
                }();

        // Last frame's deferred kitty textures resolve pre-bracket, exactly
        // where the whole-surface frame flushes them — GPU arm only.
        static if (__traits(compiles, { auto c_ = h.canvas; auto f_ = c_.fonts; }))
            if (s.terms.any)
            {
                import sparkles.terminal_view.core : flush_deferred_textures;

                (() @trusted => flush_deferred_textures())();
            }

        // Focus edges, to the active tab only — the pane either has the
        // keyboard or it does not; background tabs were never focused.
        const focusNow = terminalCaptures;
        if (focusNow != prevTermFocus)
        {
            prevTermFocus = focusNow;
            if (auto tv = store.byId(s.terms.tabs[s.terms.active].id))
                (() @trusted => tv.notifyFocus(focusNow))();
        }
    }

    /// One spawn: pre-opened here, where the host's metrics are — so the
    /// component's own open-failure path (which quits the application) can
    /// never run for a gallery tab. A failed pty reports and removes its tab.
    private void spawnOne(H)(ref H h)
    {
        const id = s.terms.spawn();
        if (id == 0)
            return;
        auto tv = store.create(id);
        if (tv is null)
        {
            s.terms.close(s.terms.active);
            return;
        }

        // The pane's cell size: last paint's rect, or a first-frame estimate
        // from the same numbers the layout will use (the grid follows the
        // real rect one frame later either way).
        ushort cols = s.terms.paneCols;
        ushort rows = s.terms.paneRows;
        if (cols == 0 || rows == 0)
        {
            const w = s.contentWidth - 2;
            const ph = paneHeight(s) - 2;
            cols = cast(ushort) (w > 1 ? w : 1);
            rows = cast(ushort) (ph > 1 ? ph : 1);
        }

        bool ok;
        static if (__traits(compiles, { auto c_ = h.canvas; auto f_ = c_.fonts; }))
            ok = () @trusted {
                auto c = h.canvas;
                return tv.open(c.fonts, cols, rows);
            }();
        else
            ok = (() @trusted => tv.openCore(cols, rows, 1, 1))();
        if (!ok)
        {
            (() @trusted => store.closeFor(id))();
            s.terms.close(s.terms.active);
            s.toastText = "terminal · could not open a pty";
            s.toast = typeof(s.toast).triggered(toastConfigFor(s.hasFrameClock));
        }
    }

    /// Down/up inside whichever half has the keyboard: the page list moves the
    /// selection, the page scrolls.
    private void moveWithin(int delta) @safe
    {
        if (s.region == Region.nav)
        {
            const n = cast(long) pages.length;
            const at = (cast(long) s.page + delta % n + n) % n;
            return setPage(cast(size_t) at);
        }
        scrollContent(delta);
    }

    private void scrollInspector(int delta) @safe
        => dock.scrollBy(paneInsp, 0, delta);

    private void scrollContent(int delta) @safe
        => dock.scrollBy(paneContent, 0, delta);

    private void setPage(size_t to) @safe
    {
        if (to >= pages.length || to == s.page)
            return;
        s.page = to;
        dock.reveal(paneNav, Rect(0, cast(int) to, 1, 1));
        // A new page starts at its top. Carrying the previous page's offset
        // would land a short page scrolled past its own end. The bar's own
        // state — hover, animation width — is kept: the pointer has not moved.
        dock.scrollTo(paneContent, 0, 0);
        // The inspector's dump is a new document too.
        dock.scrollTo(paneInsp, 0, 0);
    }

    private void cycleTheme(int delta) @safe
    {
        const n = cast(long) themeNames.length;
        selectTheme(cast(size_t)((cast(long) s.themeIndex + delta % n + n) % n));
    }

    private void selectTheme(size_t to) @safe
    {
        s.themeIndex = to % themeNames.length;
        s.toastText = "theme · " ~ s.themeName;
        s.toast = typeof(s.toast).triggered(toastConfigFor(s.hasFrameClock));
    }

    // ── pointer ─────────────────────────────────────────────────────────────

    private void onPointer(H)(ref H h, in PointerEvent device)
    {
        // Hit targets come from the frames the painter used, so painted and
        // clickable cannot drift. Rebuilding the tree here costs one extra
        // layout per pointer event and buys the invariant outright.
        auto tree = view(h);
        auto frames = layout(tree,
            Constraints(maxW: s.surface.width, maxH: s.surface.height));
        const targets = hoverTargets(tree, frames);
        PointerEvent p = device;
        if (s.guiCellW > 0 && s.guiCellH > 0)
        {
            p.pos = Point(device.pos.x / s.guiCellW,
                device.pos.y / s.guiCellH);
            s.guiPointerY = device.pos.y;
        }
        else
            s.guiPointerY = int.min;

        // The dock's dividers first (`DCK13`): a press on the seam between
        // two panes starts a resize, and a live resize owns the pointer
        // wherever it strays. Every other event falls straight through —
        // the container's pane routes are ignored, because the gallery's
        // own hover/press machinery below IS the pane handling.
        const route = dock.handle(Event(device));
        if (route.relayout)
            reflexCentre();
        if (route.kind == RouteKind.container)
        {
            s.hover.update(p, targets);
            reportPointerShape(h);
            return;
        }

        // …then the showing page's own affordances, which know geometry the
        // shell does not.
        if (pages[s.page].onPointer !is null
            && pages[s.page].onPointer(s, p, tree, frames))
        {
            s.hover.update(p, targets);
            reportPointerShape(h);
            return;
        }

        // Inside the terminal pane, the pointer belongs to the application
        // running there when it asked for mouse reporting (vim, htop): the
        // event forwards pane-relative through the mode-aware encoder, and a
        // forwarded press also focuses the pane — pointing into an app means
        // working in it. When the application does not track the mouse the
        // seam writes nothing and the shell's routing (click-to-focus,
        // hover) continues below.
        if (s.page == terminalPageIndex && s.terms.any)
        {
            const paneRect = rectOf(tree, frames, hitPane);
            if (paneRect.width > 0 && paneRect.contains(p.pos))
                if (auto tv = store.byId(s.terms.tabs[s.terms.active].id))
                {
                    const rel = PointerEvent(action: p.action,
                        button: p.button, mods: p.mods,
                        pos: Point(p.pos.x - paneRect.x, p.pos.y - paneRect.y));
                    if ((() @trusted => tv.sendPointer(rel))())
                    {
                        if (p.action == PointerAction.press)
                            s.terms.focused = true;
                        s.hover.update(p, targets);
                        reportPointerShape(h);
                        return;
                    }
                }
        }

        scope (exit)
            reportPointerShape(h);

        final switch (p.action)
        {
            case PointerAction.move:
                s.hover.update(p, targets);
                return;
            case PointerAction.drag:
                s.hover.update(p, targets);
                // A drag belongs to whatever the press captured, not to
                // whatever is under the pointer now — which is the whole point
                // of `CaptureState`, and the reason a divider does not let go
                // when you drag past the pane beside it.
                if (s.capture.ownedBy(hitSplit))
                    s.split = s.split.draggedTo(p.pos.x, splitMin,
                        splitMax(s.contentWidth - 1));
                return;
            case PointerAction.leave:
                s.hover.update(p, targets);
                s.press = s.press.cancelled;
                s.capture = s.capture.released;
                s.split = s.split.released;
                return;
            case PointerAction.press:
                s.hover.update(p, targets);
                s.press = s.press.pressed(s.hover.hot);
                if (s.hover.hot == hitSplit)
                {
                    s.capture = s.capture.capturedBy(hitSplit);
                    s.split = s.split.started(p.pos.x);
                }
                return;
            case PointerAction.release:
                s.hover.update(p, targets);
                s.press = s.press.released(s.hover.hot);
                s.capture = s.capture.released;
                s.split = s.split.released;
                activate(s.press.activated);
                return;
        }
    }

    /// What a completed press on `id` does. A release over a $(I different)
    /// target than the press activates nothing — `PressState` already refused
    /// it, and this only ever sees ids that survived that rule.
    private void activate(size_t id) @safe
    {
        if (id == 0)
            return;

        // A completed press outside the Terminal page's own chrome takes the
        // keyboard back from a focused terminal — clicking the catalog means
        // using it. Its tabs and buttons keep the capture (VSCode's shape:
        // switching tabs moves the focus, it does not drop it).
        if (s.terms.focused && !terminalOwns(id))
            s.terms.focused = false;

        if (id >= hitNav && id < hitNav + pages.length)
        {
            s.region = Region.nav;
            return setPage(id - hitNav);
        }

        // The inspector panel's own rows: select, and fold a container.
        if (inspectorActivate(s, id))
            return;

        // Anything else belongs to the page. The shell does not know what a
        // theme row or a tab is, and does not import a page to find out.
        if (pages[s.page].onActivate !is null && pages[s.page].onActivate(s, id))
            s.region = Region.content;
    }

    private void onWheel(H)(ref H h, in WheelEvent device)
    {
        noteHost(h);
        WheelEvent w = device;
        if (s.guiCellW > 0 && s.guiCellH > 0)
            w.pos = Point(device.pos.x / s.guiCellW,
                device.pos.y / s.guiCellH);

        // Over the terminal pane the wheel belongs to the application when
        // it tracks the mouse (the scroll buttons); otherwise it walks the
        // shell's scrollback — either way, not the gallery's document.
        if (s.page == terminalPageIndex && s.terms.any && s.hover.isHot(hitPane))
        {
            if (auto tv = store.byId(s.terms.tabs[s.terms.active].id))
                if ((() @trusted => tv.sendWheel(w.dy,
                        w.pos.x - s.terms.paneX, w.pos.y - s.terms.paneY))())
                    return;
            return scrollTerminal(w.dy);
        }

        // The producer already multiplied by `linesPerNotch`; multiplying again
        // here is the bug `INP12` names. Geometry comes from the dock's pane
        // frames, including the reserved bar gutters.
        const route = dock.handle(Event(device));
        if (route.kind == RouteKind.pane && route.pane == paneInsp)
            return scrollInspector(w.dy);
        if (route.kind == RouteKind.pane && route.pane == paneNav)
            return dock.scrollBy(paneNav, 0, w.dy);
        scrollContent(w.dy);
    }

    /// Scrolls the active terminal's viewport — negative into history.
    private void scrollTerminal(int deltaLines) @safe
    {
        if (!s.terms.any)
            return;
        if (auto tv = store.byId(s.terms.tabs[s.terms.active].id))
            (() @trusted => tv.scrollViewport(deltaLines))();
    }

    /**
    Asks the host for the pointer shape the interaction wants.

    A live grab outranks every hover, including one belonging to something
    else — otherwise the cursor flickers back to an arrow the moment a drag
    leaves the affordance that started it. Re-asserted on every event rather
    than only on change, because some terminals reset the pointer themselves
    when a drag begins and a repeated OSC 22 is a few idempotent bytes.
    */
    private void reportPointerShape(H)(ref H h)
    {
        // The dock's shape first: a live divider resize (or a hover over
        // one) wants the resize cursor, and outranks every pane shape.
        const ds = dock.shape();
        if (ds != PointerShape.default_)
            return h.pointerShape(ds);

        const overDivider = s.pointerAffordances && s.hover.isHot(hitSplit);
        auto want = wantedPointerShape(s.split, overDivider,
            s.demoView.v, s.demoView.h);
        h.pointerShape(want);
    }

    // ── views ───────────────────────────────────────────────────────────────

    private uint shellHeader(ref Builder b) @safe
    {
        const title = b.add(Widget(
            kind: WidgetKind.text,
            text: "sparkles:ui",
            slot: Slot.chromeAccent,
            textStyle: TextStyle(bold: true),
        ));
        const blurb = b.add(Widget(
            kind: WidgetKind.text,
            text: pages[s.page].blurb,
            slot: Slot.chrome,
        ));
        // The toast takes the header's centre when it is up, so a theme change
        // is legible without a second band appearing and shifting the layout.
        uint[] centre;
        if (s.toast.visible)
            centre ~= b.add(Widget(
                kind: WidgetKind.text,
                text: s.toastText,
                slot: Slot.chromeAccent,
                textStyle: TextStyle(bold: true),
            ));

        const themeTag = b.add(Widget(
            kind: WidgetKind.text,
            text: s.themeName,
            slot: Slot.chrome,
        ));

        // Segments are dropped by priority as the surface narrows, rather than
        // squeezed into each other: the layout engine reclaims overflow by
        // shrinking allocations, and a shrunk text run still paints its whole
        // string — so three segments that no longer fit overprint. The title
        // always survives; the blurb goes first, the theme name next.
        //
        // The toast counts as one of them. It takes the centre and is the more
        // urgent thing to read, so it displaces the blurb rather than being
        // added beside it — which is what it did at first, overprinting both.
        uint[] leading = [title];
        if (s.surface.width >= 56 && !s.toast.visible)
            leading ~= blurb;
        uint[] trailing;
        if (s.surface.width >= 40)
            trailing ~= themeTag;

        return headerBar(b, leading, centre, trailing);
    }

    private uint navPane(ref Builder b) @safe
    {
        const focused = s.region == Region.nav;
        auto rows = new uint[](pages.length);
        foreach (i, ref p; pages)
        {
            const id = hitNav + i;
            const selected = i == s.page;
            const hot = s.pointerAffordances && s.hover.isHot(id);
            const caption = b.add(Widget(
                kind: WidgetKind.text,
                text: p.title,
                slot: selected ? Slot.chromeAccent : (hot ? Slot.code : Slot.muted),
                textStyle: TextStyle(bold: selected),
            ));
            const marker = b.add(Widget(
                kind: WidgetKind.text,
                // The selection marker is text, not a background: it survives a
                // theme whose `selection` slot is barely distinguishable, and it
                // is visible on a terminal with no colour at all.
                text: selected ? (focused ? "▸ " : "· ") : "  ",
                slot: selected ? Slot.chromeAccent : Slot.muted,
            ));
            rows[i] = b.add(Widget(
                kind: WidgetKind.row,
                children: [marker, caption],
                width: SizeSpec.grow(),
                hitId: id,
                slot: selected ? Slot.selection : Slot.inherit,
                paintBackground: selected,
            ));
        }

        const list = b.add(Widget(
            kind: WidgetKind.column,
            children: rows,
            width: SizeSpec.grow(),
            padding: Insets(0, 0, 0, 1),
        ));
        const f = dock.scrollFrameOf(paneNav);
        const view_ = scrollView(b, list, cast(int) f.vExtents.viewport,
            ScrollState(dock.offsetV(paneNav)), keyNavScroll);
        b.nodes[view_].width = SizeSpec.fixed(f.content.width);
        const bar = verticalBar(b, dock.scrollOf(paneNav),
            BarGeometry(f.vExtents.content, f.vExtents.viewport,
                f.vExtents.track), 0);
        const inner = b.add(Widget(
            kind: WidgetKind.row,
            children: [view_, bar],
            width: SizeSpec.fixed(s.navCols),
        ));
        return b.add(Widget(
            kind: WidgetKind.column,
            children: [inner],
            // The dock's arranged width, not the nominal constant — this is
            // the pane the divider beside it resizes.
            width: SizeSpec.fixed(s.navCols),
            height: SizeSpec.grow(),
            clipY: true,
            clipX: true,
            decoration: Decoration(
                borderWidth: Insets(0, 1, 0, 0),
                borderStyle: BorderStyle.solid,
                borderSlot: Slot.border,
            ),
        ));
    }

    /**
    The inspector panel: the pre-built, pre-measured body in a scroll viewport
    with its own bar, in a fixed-width column bordered on the left — the
    sidebar's mirror image, down to the padding.
    */
    private uint inspectorPane(ref Builder b, uint bodyRoot, int viewport) @safe
    {
        const view_ = scrollView(b, bodyRoot, viewport,
            ScrollState(dock.offsetV(paneInsp)), keyInspScroll);
        const f = dock.scrollFrameOf(paneInsp);
        const bar = verticalBar(b, dock.scrollOf(paneInsp),
            BarGeometry(f.vExtents.content, f.vExtents.viewport,
                f.vExtents.track), hitInspBar);
        const inner = b.add(Widget(
            kind: WidgetKind.row,
            children: [view_, bar],
        ));
        return b.add(Widget(
            kind: WidgetKind.column,
            children: [inner],
            width: SizeSpec.fixed(s.inspCols),
            height: SizeSpec.grow(),
            padding: Insets(0, 0, 0, 1),
            clipX: true,
            clipY: true,
            decoration: Decoration(
                borderWidth: Insets(0, 0, 0, 1),
                borderStyle: BorderStyle.solid,
                borderSlot: Slot.border,
            ),
        ));
    }

    private uint contentPane(ref Builder b, uint pageRoot, int viewport) @safe
    {
        const view_ = scrollView(b, pageRoot, viewport,
            ScrollState(dock.offsetV(paneContent)), keyContentScroll);

        // The gutter is always there; only the bar inside it comes and goes. A
        // track beside content that fits says nothing, but a gutter that
        // appeared with it would reflow the whole page sideways the moment it
        // grew past the viewport (`GalleryState.contentWidth`).
        const f = dock.scrollFrameOf(paneContent);
        const bar = verticalBar(b, dock.scrollOf(paneContent),
            BarGeometry(f.vExtents.content, f.vExtents.viewport,
                f.vExtents.track), hitContentBar);

        return b.add(Widget(
            kind: WidgetKind.row,
            children: [view_, bar],
            width: SizeSpec.grow(),
            height: SizeSpec.grow(),
        ));
    }

    private uint statusBar(ref Builder b) @safe
    {
        uint[] hints;
        hints ~= b.add(Widget(
            kind: WidgetKind.text,
            text: s.region == Region.nav ? "pages" : "page",
            slot: Slot.chromeAccent,
            textStyle: TextStyle(bold: true),
        ));
        // The showing page's rows, straight from the one table — the prose
        // copy this used to be could drift from the handlers; a listing
        // cannot. One chip per command (the first spelling wins), so `+`
        // and `=` do not both claim a chip in a one-line bar.
        bool[GalleryCommand.max + 1] seenCmd;
        foreach (ref bnd; reachableBindings())
            if (bnd.scope_ == pages[s.page].scope_
                && bnd.scope_ != GalleryScope.always && !seenCmd[bnd.cmd])
            {
                seenCmd[bnd.cmd] = true;
                hints ~= b.add(Widget(kind: WidgetKind.text,
                    text: chordText(bnd.path[0]) ~ " " ~ bnd.desc,
                    slot: Slot.chrome));
            }

        const help = b.add(Widget(
            kind: WidgetKind.text,
            text: "? keys   q quit",
            slot: Slot.chrome,
        ));
        return headerBar(b, hints, null, [help]);
    }

    /**
    The bindings reachable in the current context, in resolution order —
    what the help overlay and the status bar render, straight from the one
    table. `contentRegion` is forced for the status bar (page keys are
    worth showing from the nav too) and live for the overlay.
    */
    private Binding[] listedBindings(bool contentRegion) const @safe
    {
        Binding[] listed;
        bindingsAt(listed, GalleryContext(pageScope: pages[s.page].scope_,
            contentRegion: contentRegion));
        return listed;
    }

    /// ditto — the status bar's cut.
    private Binding[] reachableBindings() const @safe
        => listedBindings(true);

    /**
    The nav fallback's cut (`pageDeclinedFromNav`): the showing page's rows
    that still fire from the page list — those no shell row claims first.
    Empty in the content region, where the main listing already carries the
    page's rows; listed $(B after) the shell's, which is their resolution
    order there.
    */
    private Binding[] navFallbackRows() const @safe
    {
        Binding[] extra;
        if (s.region == Region.content)
            return extra;
        const first = listedBindings(false);
        foreach (ref bnd; listedBindings(true))
        {
            if (bnd.scope_ != pages[s.page].scope_
                || bnd.scope_ == GalleryScope.always)
                continue;
            bool shadowed;
            foreach (ref seen; first)
                // `acceptsTyped`-shaped: a shift-agnostic shell row claims
                // both spellings, so the page's row is dead in the nav
                // region whichever shift it names.
                if (acceptsTyped(seen.path[0], bnd.path[0]))
                {
                    shadowed = true;
                    break;
                }
            if (!shadowed)
                extra ~= bnd;
        }
        return extra;
    }

    private uint helpOverlay(ref Builder b) @safe
    {
        uint[] lines;
        lines ~= b.add(Widget(
            kind: WidgetKind.text,
            text: "bindings",
            slot: Slot.chromeAccent,
            textStyle: TextStyle(bold: true),
        ));
        lines ~= hrule(b);
        // The listing IS the table (`KEY3`): whatever is reachable right
        // here — the showing page's rows first, then the shell's — in
        // resolution order, so the overlay cannot describe a key the shell
        // would resolve differently.
        foreach (ref bnd; listedBindings(s.region == Region.content))
            lines ~= keyHint(b, chordText(bnd.path[0]), bnd.desc);
        // From the page list, the showing page's unshadowed keys still fire
        // (the fallback rung) — so the overlay lists them too, after the
        // shell's, which is their resolution order there.
        foreach (ref bnd; navFallbackRows())
            lines ~= keyHint(b, chordText(bnd.path[0]), bnd.desc);
        // …plus the terminal grab's policy, which routes before the table.
        lines ~= keyHint(b,
            chordText(terminalGrabPolicy.release[0]) ~ " / "
                ~ chordText(terminalGrabPolicy.release[1]),
            "give the keyboard back to the gallery");
        lines ~= keyHint(b,
            chordText(terminalGrabPolicy.passthrough[0]) ~ " / "
                ~ chordText(terminalGrabPolicy.passthrough[1]),
            "a focused terminal's scrollback");

        const popup = b.add(Widget(
            kind: WidgetKind.popup,
            children: [b.add(Widget(kind: WidgetKind.column, children: lines))],
            slot: Slot.surface,
            padding: Insets.symmetric(1, 2),
            paintBackground: true,
            decoration: Decoration(
                borderWidth: Insets.all(1),
                borderStyle: BorderStyle.solid,
                borderSlot: Slot.border,
                shadow: true,
            ),
        ));
        // Centred by the layout engine's own alignment over a full-surface
        // column, so nothing here measures a label or divides a width.
        return b.add(Widget(
            kind: WidgetKind.column,
            children: [popup],
            width: SizeSpec.grow(),
            height: SizeSpec.grow(),
            alignX: Alignment.center,
            alignY: Alignment.center,
        ));
    }

    private int measureHeight(ref Builder b, uint root, int width) @safe
    {
        // A throwaway layout of the page subtree alone. It is the same engine
        // and the same constraints the real pass uses, so the number is the one
        // the frame will actually have — not an estimate the scrollbar would
        // then contradict.
        auto probe = WidgetTree(b.nodes, root);
        return layout(probe, Constraints(maxW: width))[root].rect.height;
    }
}

private auto rgbOr(C)(in C c, ubyte r, ubyte g, ubyte bl) @safe
{
    import sparkles.base.term_color : Color, RgbColor;

    return c.kind == Color.Kind.rgb ? c.rgb : RgbColor(r, g, bl);
}

/// `a` blended toward `b` by `t` — hue's scrollbar color recipe, over the
/// page colors so the rail follows the theme.
private auto mixRgb(C)(in C a, in C b, float t) @safe
    => C(cast(ubyte)(a.r + (b.r - a.r) * t),
        cast(ubyte)(a.g + (b.g - a.g) * t),
        cast(ubyte)(a.b + (b.b - a.b) * t));

// ---------------------------------------------------------------------------
// Tests — the whole shell, headless, through the recording host.
// ---------------------------------------------------------------------------

version (unittest)
{
    import pages.themes_page : themeAt;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : runAppRecorded;
    import sparkles.input : charEvent, keyEvent, Mods, PointerButton;
    import sparkles.ui_app.host : RunConfig;

    // A run at a given surface, with the shell's own default state.
    // Attributes are explicit: a non-templated helper does NOT infer them, so
    // an unannotated one is `@system` and drags every unittest calling it out
    // of `@safe` — the lesson `record.d` already wrote down.
    private RecordingHost drive(ref Gallery g, in Event[] script,
        int cols = 80, int rows = 24) @safe
    {
        return runAppRecorded(g, RunConfig.init, script,
            (ref RecordingHost h) { h.size = sizeOf(cols, rows); });
    }

    private auto sizeOf(int w, int h) @safe pure nothrow @nogc
    {
        import sparkles.ui.geometry : Size;

        return Size(w, h);
    }
}

@("ui_gallery.gallery.isAComponent")
@safe unittest
{
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : isAppFor;

    // The concept, checked against the host every test drives it on. A member
    // template that failed to instantiate would otherwise surface as a
    // mysterious "not a component" at the call site.
    static assert(isAppFor!(Gallery, RecordingHost));
}

@("ui_gallery.gallery.drawsBeforeAnythingHappensToIt")
@safe unittest
{
    Gallery g;
    auto rec = drive(g, Event[].init);

    assert(rec.frames.length == 1, "one frame before any input");
    assert(!rec.frames[0].skipped);
    // The page fill, then the shell. A frame carrying only the fill would mean
    // the tree never reached the display list.
    assert(rec.frames[0].ops.length > 1);
}

@("ui_gallery.gallery.quits")
@safe unittest
{
    // `runRecorded` stops at the quit, so this needs no padding — and the two
    // spellings of "go away" both work.
    Gallery g;
    assert(drive(g, [charEvent('q'), charEvent('j')]).quitRequested);

    Gallery g2;
    assert(drive(g2, [keyEvent(Key.escape)]).quitRequested);
}

@("ui_gallery.gallery.aPageKeyWorksFromEitherRegion")
@safe unittest
{
    import registry : pageIndexOf;
    import pages.dock_page : docPane, notesPane, sidePane;

    // The reported defect: the status bar lists a page's keys unconditionally,
    // but in the nav region the page was never asked, so every advertised key
    // was inert until the reader happened to discover Tab.
    Gallery g;
    g.s.page = pageIndexOf("dock");
    assert(g.s.region == Region.nav, "the shell starts on the page list");

    drive(g, [charEvent('f')]);        // focus the next pane: doc -> sidebar
    assert(g.s.dock.focused == sidePane, "a page key reaches the page from nav");

    drive(g, [charEvent('f')]);        // and back onto the tabbed group
    assert(g.s.dock.focused == docPane);

    drive(g, [charEvent('.')]);        // the tab route, from the nav region
    assert(g.s.dock.focused == notesPane);

    const wide = g.s.dock.paneExtent(sidePane);
    drive(g, [charEvent('h')]);
    assert(g.s.dock.paneExtent(sidePane) < wide, "and the resize route");
}

@("ui_gallery.gallery.theNavRegionKeepsItsOwnKeysFromThePage")
@safe unittest
{
    import registry : pageIndexOf;

    // The other half of the rule: the page is asked LAST in the nav region, so
    // a page that binds a key the shell uses cannot take the list's keys away.
    // The tree page owns the arrows in the content region; from the nav region
    // they must still move between pages.
    Gallery g;
    g.s.page = pageIndexOf("tree");
    const was = g.s.page;
    drive(g, [keyEvent(Key.right)]);
    assert(g.s.page != was, "the arrows still walk the page list");

    drive(g, [keyEvent(Key.down)]);
    assert(g.s.region == Region.nav, "and down moves the selection, not focus");
}

@("ui_gallery.gallery.tabSwitchesTheFocusedRegion")
@safe unittest
{
    Gallery g;
    assert(g.s.region == Region.nav);
    drive(g, [keyEvent(Key.tab)]);
    assert(g.s.region == Region.content);
    drive(g, [keyEvent(Key.tab)]);
    assert(g.s.region == Region.nav);
}

@("ui_gallery.gallery.themeCyclingChangesWhatIsPainted")
@safe unittest
{
    // Not "the name changed" — the ops changed. This is the assertion that
    // would fail if the theme were resolved once at startup, which is the whole
    // reason the component declares `theme`.
    Gallery g;
    const before = g.theme.pageBg;
    auto rec = drive(g, [charEvent(']')]);

    assert(g.s.themeIndex == 8);
    assert(g.theme.pageBg != before || g.theme.palette != AppTheme.init.palette);

    // The page fill is op 0 on every frame; its background is the theme's.
    const first = rec.frames[0].ops[0].visual.bg;
    const last = rec.frames[$ - 1].ops[0].visual.bg;
    assert(first != last, "the page background follows the selected theme");
}

@("ui_gallery.gallery.themeCyclingWraps")
@safe unittest
{
    Gallery g;
    g.s.themeIndex = 0;
    drive(g, [charEvent('[')]);
    assert(g.s.themeIndex == themeNames.length - 1, "backwards from the first wraps");
    drive(g, [charEvent(']')]);
    assert(g.s.themeIndex == 0);
}

@("ui_gallery.gallery.helpOverlayIsModal")
@safe unittest
{
    // The defect this rules out: an overlay that paints over the page while the
    // page still consumes the keys behind it.
    Gallery g;
    const page = g.s.page;
    drive(g, [charEvent('?'), keyEvent(Key.right), keyEvent(Key.down)]);

    assert(g.s.helpOpen);
    assert(g.s.page == page, "keys under a modal do not reach the page");

    drive(g, [keyEvent(Key.escape)]);
    assert(!g.s.helpOpen, "dismiss closes the overlay");
}

@("ui_gallery.gallery.escapeClosesTheOverlayRatherThanQuitting")
@safe unittest
{
    // Dismiss is a chain, and the overlay is the innermost link: the first
    // Escape closes it, the second quits.
    Gallery g;
    auto rec = drive(g, [charEvent('?'), keyEvent(Key.escape)]);
    assert(!g.s.helpOpen);
    assert(!rec.quitRequested, "the overlay consumed the dismissal");
}

@("ui_gallery.gallery.theInspectorPanelSitsBesideThePageItDumps")
@safe unittest
{
    // The reason the inspector stopped being a page: its subject was never on
    // screen while its dump was. As a panel the two share the frame — the
    // tree carries the page AND a dump that names it.
    Gallery g;
    g.s.page = 1; // Primitives
    drive(g, [charEvent('|')], 120, 40);
    assert(g.s.inspectorOpen && g.s.inspectorVisible);

    RecordingHost h;
    h.size = sizeOf(120, 40);
    auto tree = g.view(h);
    bool title;
    foreach (ref n; tree.nodes)
        foreach (ref sp; n.spans)
            title |= sp.text == "inspector · Primitives";
    assert(title, "the panel is in the frame and names the page beside it");

    // The page narrowed to make room, and the second press closes it again.
    assert(g.s.contentWidth
        == 120 - (navWidth + 1) - (inspectorWidth + 1) - scrollGutter);
    drive(g, [charEvent('|')], 120, 40);
    assert(!g.s.inspectorOpen);
}

@("ui_gallery.gallery.theInspectorFollowsThePage")
@safe unittest
{
    import registry : pageIndexOf;

    // Moving pages re-aims the dump at the new subject and rewinds it — the
    // dump is a new document, not the old one scrolled somewhere.
    Gallery g;
    g.s.inspectorOpen = true;
    g.s.page = pageIndexOf("primitives");
    RecordingHost first;
    first.size = sizeOf(120, 40);
    g.view(first);
    g.dock.scrollTo(Gallery.paneInsp, 0, 12);
    drive(g, [keyEvent(Key.right)], 120, 40);

    import std.algorithm.searching : canFind;

    RecordingHost h;
    h.size = sizeOf(120, 40);
    auto tree = g.view(h);
    bool subject;
    foreach (ref n; tree.nodes)
        foreach (ref sp; n.spans)
            subject |= sp.text.canFind(pages[g.s.page].title);
    assert(subject, "the panel names the page now showing");
    assert(g.dock.offsetV(Gallery.paneInsp) == 0,
        "a new subject starts at its top");
}

@("ui_gallery.gallery.theWheelOverTheInspectorScrollsTheDumpNotThePage")
@safe unittest
{
    // The panel's columns are the surface's rightmost `inspectorWidth`; a
    // wheel there moves the dump and leaves the page alone — and vice versa.
    Gallery g;
    g.s.inspectorOpen = true;
    drive(g, [Event(WheelEvent(dy: 3, pos: Point(119, 10)))], 120, 40);
    assert(g.dock.offsetV(Gallery.paneInsp) > 0, "the dump scrolled");
    assert(g.dock.offsetV(Gallery.paneContent) == 0, "the page did not");

    const dumpAt = g.dock.offsetV(Gallery.paneInsp);
    drive(g, [Event(WheelEvent(dy: 3, pos: Point(40, 10)))], 120, 40);
    assert(g.dock.offsetV(Gallery.paneInsp) == dumpAt,
        "a wheel over the page leaves the dump");
}

@("ui_gallery.gallery.theInspectorBarIsGrabbable")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;

    // `UGL16`, on the panel's own bar: a press on its track jumps the dump.
    Gallery g;
    g.s.inspectorOpen = true;
    g.s.surface = sizeOf(120, 40);
    RecordingHost h;
    h.size = sizeOf(120, 40);
    auto tree = g.view(h);
    layout(tree, Constraints(maxW: 120, maxH: 40));
    const bar = g.dock.scrollFrameOf(Gallery.paneInsp).vTrack;
    assert(bar.width > 0, "the panel's bar is in the frame");

    const press = Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left,
        pos: Point(bar.x + bar.width - 1, bar.y + bar.height / 2)));
    drive(g, [press], 120, 40);
    assert(g.dock.scrollOf(Gallery.paneInsp).v.dragging,
        "the press grabbed the bar");
    assert(g.dock.offsetV(Gallery.paneInsp) > 0, "…and jumped the dump");
}

version (unittest)
{
    private Event pointerAt(PointerAction a, int x, int y) @safe
        => Event(PointerEvent(action: a, button: PointerButton.left,
            pos: Point(x, y)));
}

@("ui_gallery.gallery.draggingTheNavDividerResizesTheSidebar")
@safe unittest
{
    // The seam between the sidebar and the page is the dock's divider: a
    // press on the gap column grabs it, the drag re-tiles, and the page's
    // width follows the same mirror every pure view reads.
    Gallery g;
    drive(g, [
        pointerAt(PointerAction.press, navWidth, 5),
        pointerAt(PointerAction.drag, 30, 5),
        pointerAt(PointerAction.release, 30, 5),
    ], 120, 40);

    assert(g.s.navCols == 30, "the sidebar followed the divider");
    assert(g.s.contentWidth == 120 - 31 - scrollGutter,
        "the page gave up exactly what the sidebar took");
    assert(!g.dock.resizing, "the release ended the grab");

    // The drag clamps at both ends: a third of the surface, and the floor.
    drive(g, [
        pointerAt(PointerAction.press, 30, 5),
        pointerAt(PointerAction.drag, 110, 5),
        pointerAt(PointerAction.release, 110, 5),
    ], 120, 40);
    assert(g.s.navCols == 120 / 3, "the ceiling held");

    drive(g, [
        pointerAt(PointerAction.press, 40, 5),
        pointerAt(PointerAction.drag, 2, 5),
        pointerAt(PointerAction.release, 2, 5),
    ], 120, 40);
    assert(g.s.navCols == navMinCols, "the floor held");
}

@("ui_gallery.gallery.draggingTheInspectorDividerKeepsTheCentreFlexible")
@safe unittest
{
    // The inspector divider's BEFORE node is the flexible centre, and a
    // divider drag fixes its before node — the dock finding `reflexCentre`
    // answers. Without it, the page stops following the window the moment
    // this divider is touched.
    Gallery g;
    g.s.inspectorOpen = true;

    const div = 120 - inspectorWidth - 1;
    drive(g, [
        pointerAt(PointerAction.press, div, 5),
        pointerAt(PointerAction.drag, div - 7, 5),
        pointerAt(PointerAction.release, div - 7, 5),
    ], 120, 40);
    assert(g.s.inspCols == inspectorWidth + 7,
        "the panel took what the drag gave it");

    // Widen the window: every new column lands in the CENTRE — the sides
    // keep their dragged widths, which is what "flexible" means here.
    drive(g, [Event(ResizeEvent(sizeOf(140, 40)))], 140, 40);
    assert(g.s.inspCols == inspectorWidth + 7 && g.s.navCols == navWidth);
    assert(g.s.contentWidth
        == 140 - (navWidth + 1) - (g.s.inspCols + 1) - scrollGutter);
}

@("ui_gallery.gallery.aHiddenPaneComesBackAtItsDraggedWidth")
@safe unittest
{
    Gallery g;
    g.s.inspectorOpen = true;
    const div = 120 - inspectorWidth - 1;
    drive(g, [
        pointerAt(PointerAction.press, div, 5),
        pointerAt(PointerAction.drag, div - 6, 5),
        pointerAt(PointerAction.release, div - 6, 5),
        charEvent('|'),
    ], 120, 40);
    assert(!g.s.inspectorOpen);

    drive(g, [charEvent('|')], 120, 40);
    assert(g.s.inspectorOpen);
    assert(g.s.inspCols == inspectorWidth + 6,
        "the width survived the round trip");
}

@("ui_gallery.gallery.navRowsTileTheSidebarAndHitWhereTheyPaint")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.state : HoverState;

    // The `IXR27` invariant, on the shell's own chrome: the hit rects come from
    // the very frames the painter used, so a row cannot be clickable somewhere
    // it is not drawn.
    Gallery g;
    g.s.surface = sizeOf(80, 24);
    RecordingHost h;
    h.size = sizeOf(80, 24);
    auto tree = g.view(h);
    auto frames = layout(tree, Constraints(maxW: 80, maxH: 24));
    const targets = hoverTargets(tree, frames);

    HoverState hover;
    foreach (i, ref p; pages)
    {
        // Row i sits under the header band, one row per page.
        hover.update(PointerEvent(action: PointerAction.move,
            pos: Point(3, cast(int)(1 + i))), targets);
        assert(hover.hot == hitNav + i, "nav row " ~ p.title ~ " hit mismatch");
    }
}

@("ui_gallery.gallery.theShellsBandsTileTheSurfaceAndNeverOverlap")
@safe unittest
{
    import registry : pages;
    import sparkles.ui.geometry : Constraints;

    // The defect this rules out, found on a 12-row terminal: the sidebar's
    // natural height exceeded the surface, the root column reclaimed the
    // difference from the header, and the page was drawn on top of it. Bands
    // that tile — each starting where the last ended, together spanning the
    // surface — cannot express that.
    static immutable int[2][] surfaces =
        [[80, 24], [120, 40], [60, 12], [46, 8], [30, 6]];

    foreach (i, ref p; pages)
        foreach (ref wh; surfaces)
        {
            Gallery g;
            g.s.page = i;
            RecordingHost h;
            h.size = sizeOf(wh[0], wh[1]);
            auto tree = g.view(h);
            auto frames = layout(tree, Constraints(maxW: wh[0], maxH: wh[1]));

            // The root is the shell column (or the stack over it when the help
            // overlay is open, which it is not here).
            const bands = tree.nodes[tree.root].children;
            assert(bands.length == 3, "header, body, footer");

            int edge = frames[tree.root].rect.y;
            foreach (band; bands)
            {
                assert(frames[band].rect.y == edge,
                    p.title ~ ": the shell's bands overlap");
                edge += frames[band].rect.height;
            }
            assert(edge <= wh[1], p.title ~ ": the shell exceeds the surface");
            assert(frames[bands[0]].rect.height == 1, "the header is one row");
            assert(frames[bands[2]].rect.height == 1, "so is the status bar");
        }
}

@("ui_gallery.gallery.theContentBarIsGrabbable")
@safe unittest
{
    import registry : pageIndexOf;
    import sparkles.ui.geometry : Constraints;

    // The bug this fixes: the shell drew a correct thumb over a bare
    // `ScrollState` and wired no pointer path at all, so the bar was a
    // picture. Press it, drag it, and the page must move.
    Gallery g;
    g.s.page = pageIndexOf("slots"); // long enough to overflow any surface

    RecordingHost h;
    h.size = sizeOf(96, 24);
    auto tree = g.view(h);
    auto frames = layout(tree, Constraints(maxW: 96, maxH: 24));
    const bar = rectOf(tree, frames, hitContentBar);
    assert(!bar.empty, "the content bar is not painted");

    // A press near the bottom of the track jumps the thumb there…
    const low = Point(bar.x, bar.y + bar.height - 2);
    drive(g, [Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left, pos: low))], 96, 24);
    const jumped = g.dock.offsetV(Gallery.paneContent);
    assert(jumped > 0, "a press on the track moves the page");
    assert(g.dock.scrollOf(Gallery.paneContent).v.dragging,
        "…and takes the grab");

    // …a drag back to the top brings it home, even though the pointer has
    // left the bar's own column entirely.
    drive(g, [Event(PointerEvent(action: PointerAction.drag,
        button: PointerButton.left, pos: Point(2, bar.y)))], 96, 24);
    assert(g.dock.offsetV(Gallery.paneContent) < jumped,
        "the drag tracked the pointer");

    drive(g, [Event(PointerEvent(action: PointerAction.release,
        button: PointerButton.left, pos: Point(2, bar.y)))], 96, 24);
    assert(!g.dock.scrollOf(Gallery.paneContent).v.dragging);
    assert(g.s.capture.isFree, "the release freed the pointer for everything");
}

@("ui_gallery.gallery.componentsScrollbarsReachThePageThroughTheShell")
@safe unittest
{
    import registry : pageIndexOf;
    import sparkles.ui.geometry : Constraints;

    // Page-local machines are useful only if the shell offers them the event.
    // Keep this at the full composition boundary: dock routing runs first,
    // then the Components page must still receive a press in its specimen.
    Gallery g;
    g.s.page = pageIndexOf("components");

    RecordingHost h;
    h.size = sizeOf(120, 70);
    auto tree = g.view(h);
    const bar = rectOf(tree,
        layout(tree, Constraints(maxW: 120, maxH: 70)), hitChromeSamples);
    assert(!bar.empty && bar.y < 70, "the specimen is visible in the frame");

    drive(g, [Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left,
        pos: Point(bar.x, bar.y + bar.height - 1)))], 120, 70);
    assert(g.s.componentBars[0].v.offset > 0,
        "the shell delivered the press to the Components page");
    assert(g.s.componentBars[0].v.dragging);

    drive(g, [Event(PointerEvent(action: PointerAction.release,
        button: PointerButton.left,
        pos: Point(bar.x, bar.y + bar.height - 1)))], 120, 70);
    assert(!g.s.componentBars[0].v.dragging && g.s.capture.isFree);
}

@("ui_gallery.gallery.aScrollbarGrabDoesNotAlsoPressWhatItPassesOver")
@safe unittest
{
    import registry : pageIndexOf;
    import sparkles.ui.geometry : Constraints;

    // A grab owns the pointer. Dragging the bar across the page list must not
    // arm a nav row — the failure every hand-wired bar has, where letting go
    // over the sidebar navigates somewhere.
    Gallery g;
    g.s.page = pageIndexOf("slots");

    RecordingHost h;
    h.size = sizeOf(96, 24);
    auto tree = g.view(h);
    const bar = rectOf(tree, layout(tree, Constraints(maxW: 96, maxH: 24)),
        hitContentBar);

    const page = g.s.page;
    drive(g, [
        Event(PointerEvent(action: PointerAction.press,
            button: PointerButton.left, pos: Point(bar.x, bar.y + 4))),
        Event(PointerEvent(action: PointerAction.drag,
            button: PointerButton.left, pos: Point(3, 2))),
        Event(PointerEvent(action: PointerAction.release,
            button: PointerButton.left, pos: Point(3, 2))),
    ], 96, 24);

    assert(g.s.page == page, "the drag did not activate a nav row");
    assert(g.s.press.activated == 0);
}

@("ui_gallery.gallery.hoveringTheBarWidensItOverSeveralFrames")
@safe unittest
{
    import registry : pageIndexOf;
    import sparkles.ui.geometry : Constraints;

    // The second half of the report: no animation. The width is eased, so the
    // bar takes several frames to widen — and the frames it needs are the ones
    // it asks for, or the transition would stall wherever the pointer stopped.
    Gallery g;
    g.s.page = pageIndexOf("slots");

    RecordingHost h;
    h.size = sizeOf(96, 24);
    auto tree = g.view(h);
    const bar = rectOf(tree, layout(tree, Constraints(maxW: 96, maxH: 24)),
        hitContentBar);
    const narrow = g.dock.scrollOf(Gallery.paneContent).vAnim.percent;

    auto rec = drive(g, [Event(PointerEvent(action: PointerAction.move,
        pos: Point(bar.x, bar.y + 3)))], 96, 24);

    assert(g.dock.scrollOf(Gallery.paneContent).v.hovered,
        "the bar knows the pointer is on it");
    assert(g.dock.scrollOf(Gallery.paneContent).vAnim.percent > narrow,
        "and it is widening");
    assert(rec.frames.length > 2,
        "the run kept framing until the ease finished");
    assert(!rec.frames[$ - 1].requested, "…and then stopped");
}

@("ui_gallery.gallery.theRegionDecidesTheORDEROfRefusal")
@safe unittest
{
    import registry : pageIndexOf;

    // This test used to assert the opposite — that a page owns its keys ONLY
    // while the keyboard is in it — and that rule was reported as a bug,
    // correctly: the status bar lists a page's keys in both regions, so a
    // reader on the page list pressed an advertised key and nothing happened.
    // The region now decides the ORDER of refusal, not whether the page is
    // asked at all. Its original guard is kept below, because that part was
    // right: a page must not take the list's own keys.
    Gallery g;
    g.s.page = pageIndexOf("layout");
    g.s.region = Region.nav;

    drive(g, [charEvent('w')]);
    assert(g.s.layoutDemo.widthMode == 1,
        "a key the shell does not claim reaches the page from the list");

    drive(g, [keyEvent(Key.tab), charEvent('w')]);
    assert(g.s.region == Region.content);
    assert(g.s.layoutDemo.widthMode == 2, "…and from the page itself");

    // The guard: `j`/`k` walk the page list even on a page that binds them,
    // because in the nav region the shell is asked first.
    g.s.region = Region.nav;
    const was = g.s.page;
    drive(g, [charEvent('j')]);
    assert(g.s.page != was, "the shell keeps its own keys in the list");
}

@("ui_gallery.gallery.aFocusedTerminalOwnsTheKeyboard")
@safe unittest
{
    import registry : terminalPageIndex;

    // With a terminal focused, `q` must not quit, `Tab` must not move the
    // region, and `[` must not change the theme — they are the shell's keys
    // now. The run itself proves the first: a quit would end the script
    // early and record fewer frames.
    Gallery g;
    g.s.page = terminalPageIndex;
    g.s.region = Region.content;
    cast(void) g.s.terms.spawn(); // the model only — no pty in a test
    g.s.terms.focused = true;
    const theme = g.s.themeIndex;

    auto rec = drive(g, [charEvent('q'), keyEvent(Key.tab), charEvent('[')]);
    assert(!rec.quitRequested, "no key reached the shell's quit");
    assert(g.s.region == Region.content, "Tab went to the pty, not the shell");
    assert(g.s.themeIndex == theme);
    assert(g.s.terms.focused, "only the chord releases the capture");
}

@("ui_gallery.gallery.theChordAlwaysReturnsTheKeyboard")
@safe unittest
{
    import registry : terminalPageIndex;
    import sparkles.input : Mods;

    Gallery g;
    g.s.page = terminalPageIndex;
    g.s.region = Region.content;
    cast(void) g.s.terms.spawn();
    g.s.terms.focused = true;

    drive(g, [charEvent(']', Mods(ctrl: true))]);
    assert(!g.s.terms.focused, "Ctrl+] is never the shell's to keep");

    // And the shell is really back: the next `q` ends the run first thing.
    g.s.terms.focused = true;
    auto rec = drive(g, [charEvent('`', Mods(ctrl: true)), charEvent('q')]);
    assert(!g.s.terms.focused);
    assert(rec.quitRequested, "the q after the chord reached the shell");
}

@("ui_gallery.gallery.theOverlayListsTheNavFallback")
@safe unittest
{
    import registry : pageIndexOf;

    // From the page list, the overlay must list exactly the page keys the
    // fallback makes live — and none the shell would take first, or the
    // overlay advertises a key that does something else.
    Gallery g;
    g.s.page = pageIndexOf("components");
    assert(g.s.region == Region.nav);

    bool sawLive, sawArrow, sawRange;
    foreach (ref bnd; g.navFallbackRows())
    {
        sawLive |= bnd.cmd == GalleryCommand.compScrollDown; // 'n' — unclaimed
        sawArrow |= bnd.cmd == GalleryCommand.compTabNext;   // → is the shell's
        sawRange |= bnd.cmd == GalleryCommand.compAction;    // 1-4 inside 1-9
    }
    assert(sawLive, "an unclaimed page key is listed — it fires from here");
    assert(!sawArrow, "a shell-claimed arrow is not — the shell takes it");
    assert(!sawRange, "…nor a range the shell's own range covers");

    // In the content region the main listing already carries the page's
    // rows, so the fallback cut is empty rather than a duplicate.
    g.s.region = Region.content;
    assert(g.navFallbackRows().length == 0);
}

@("ui_gallery.gallery.captureReleaseChordSpellings")
@safe pure nothrow @nogc unittest
{
    import sparkles.input : Mods;
    import sparkles.ui.focus : checkGrab, GrabVerdict, KeyGrab;
    import keymap : normaliseGrabKey, terminalGrabPolicy;

    // Every spelling an input layer might deliver releases the grab; text
    // and the shell's own interrupt stay the pty's.
    static bool releases(in KeyEvent k) @safe pure nothrow @nogc
    {
        KeyGrab g;
        g.take(1);
        return checkGrab(g, normaliseGrabKey(k), terminalGrabPolicy)
            == GrabVerdict.released;
    }

    assert(releases(KeyEvent(Key.char_, ']', Mods(ctrl: true))));
    assert(releases(KeyEvent(Key.char_, '`', Mods(ctrl: true))));
    assert(releases(KeyEvent(Key.char_, '\x1d')));
    assert(!releases(KeyEvent(Key.char_, ']')), "a bare ] is text");
    assert(!releases(KeyEvent(Key.char_, 'c', Mods(ctrl: true))),
        "Ctrl+C is the shell's interrupt, never the gallery's");
}

@("ui_gallery.gallery.terminalTabHoverRevealsTheClose")
@safe unittest
{
    import pages.terminal_page : closeHit, tabHit;
    import registry : terminalPageIndex;
    import sparkles.input : PointerAction, PointerEvent;
    import sparkles.ui.state : hoverTargets;

    // The ✕ is hover-revealed: absent from a cold tree, present (with the
    // close lane's hit id) once the pointer rests on the tab's row — driven
    // through the real event path, not by poking the hover state.
    Gallery g;
    g.s.page = terminalPageIndex;
    g.s.surface = sizeOf(100, 30);
    const id = g.s.terms.spawn();

    // Find the tab row's painted rect the way the shell does.
    RecordingHost h;
    h.size = sizeOf(100, 30);
    auto tree = g.view(h);
    auto frames = layout(tree,
        Constraints(maxW: g.s.surface.width, maxH: g.s.surface.height));
    const targets = hoverTargets(tree, frames);
    Point at;
    bool found;
    foreach (t; targets)
        if (t.hitId == tabHit(id))
        {
            at = Point(t.rect.x + 1, t.rect.y);
            found = true;
        }
    assert(found, "the tab row must be hit-testable");

    bool hasClose()
    {
        auto b2 = Builder();
        auto t2 = b2.finish(pages[g.s.page].view(b2, g.s));
        foreach (ref n; b2.nodes)
            if (n.kind == WidgetKind.text && n.text == "✕"
                && n.hitId == closeHit(id))
                return true;
        cast(void) t2;
        return false;
    }

    assert(!hasClose, "no pointer, no close button");
    drive(g, [Event(PointerEvent(action: PointerAction.move, pos: at))],
        100, 30);
    assert(g.s.hover.isHot(tabHit(id)));
    assert(hasClose, "a hovered row reveals its ✕");
}

@("ui_gallery.gallery.tabIsNeverThePagesToTake")
@safe unittest
{
    import registry : pageIndexOf;

    // Whatever a page claims, Tab gets a reader back out. A page that could
    // capture it could strand them inside itself with no keyboard route home.
    Gallery g;
    g.s.page = pageIndexOf("tree");
    g.s.region = Region.content;
    drive(g, [keyEvent(Key.tab)]);
    assert(g.s.region == Region.nav);
}

@("ui_gallery.gallery.aSplitDragIsOwnedByThePress")
@safe unittest
{
    import registry : pageIndexOf;
    import sparkles.ui.geometry : Constraints;

    // Press the divider, then drag well past the pane beside it. The capture
    // keeps every subsequent move, so the divider follows the pointer instead
    // of letting go the moment the pointer is over something else.
    Gallery g;
    g.s.page = pageIndexOf("split");
    const before = g.s.split.size;

    RecordingHost h;
    h.size = sizeOf(96, 30);
    auto tree = g.view(h);
    const targets = hoverTargets(tree, layout(tree, Constraints(maxW: 96, maxH: 30)));

    Point grab;
    bool found;
    foreach (t; targets)
        if (t.hitId == hitSplit)
        {
            grab = Point(t.rect.x, t.rect.y + 1);
            found = true;
            break;
        }
    assert(found, "the divider is not hit-testable");

    drive(g, [
        Event(PointerEvent(action: PointerAction.press, pos: grab)),
        Event(PointerEvent(action: PointerAction.drag,
            pos: Point(grab.x + 6, grab.y))),
    ], 96, 30);

    assert(g.s.split.size == before + 6, "the pane followed the delta");
    assert(g.s.split.dragging, "and the grab is still in flight");

    drive(g, [Event(PointerEvent(action: PointerAction.release,
        pos: Point(grab.x + 6, grab.y)))], 96, 30);
    assert(!g.s.split.dragging);
    assert(g.s.split.size == before + 6, "the size survives the release");
}

@("ui_gallery.gallery.clickingAThemeRowSelectsIt")
@safe unittest
{
    import registry : pageIndexOf;
    import sparkles.ui.geometry : Constraints;

    // A page mints hit ids from its own base and the shell routes them back —
    // the seam that lets a page be interactive without the shell knowing what
    // it is showing. The click point comes from the target the painter used,
    // so this cannot pass by clicking somewhere the row is not drawn.
    Gallery g;
    g.s.page = pageIndexOf("themes");
    g.s.themeIndex = 10;

    RecordingHost h;
    h.size = sizeOf(96, 30);
    auto tree = g.view(h);
    const targets = hoverTargets(tree, layout(tree, Constraints(maxW: 96, maxH: 30)));

    // The row for whichever theme the list happens to be showing first.
    size_t wanted = size_t.max;
    Point at;
    foreach (t; targets)
    {
        const which = themeAt(t.hitId);
        if (which != size_t.max && which != g.s.themeIndex)
        {
            wanted = which;
            at = Point(t.rect.x + 1, t.rect.y);
            break;
        }
    }
    assert(wanted != size_t.max, "no theme row is hit-testable");

    drive(g, [
        Event(PointerEvent(action: PointerAction.press, pos: at)),
        Event(PointerEvent(action: PointerAction.release, pos: at)),
    ], 96, 30);
    assert(g.s.themeIndex == wanted);
}

@("ui_gallery.gallery.noPageOverflowsTheSurfaceSideways")
@safe unittest
{
    import registry : pages;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.widget : Visibility;

    // The shell-level twin of the catalog sweep's own width check — which
    // measures a page against the pane it is *told* it has. This measures the
    // assembled frame, and so catches the case the first one cannot: a pane
    // whose advertised width did not account for the chrome beside it.
    //
    // The invariant is "nothing overflows unless it is deliberately clipped".
    // A node under a `clipX` ancestor is allowed past the edge — that is what
    // clipping is for, and the display list culls it — so the walk carries the
    // clip state down rather than testing every frame blindly.
    static immutable int[2][] surfaces = [[80, 24], [120, 40], [46, 12]];
    foreach (i, ref p; pages)
        foreach (ref wh; surfaces)
        {
            Gallery g;
            RecordingHost h;
            h.size = sizeOf(wh[0], wh[1]);
            g.s.page = i;
            auto tree = g.view(h);
            auto frames = layout(tree, Constraints(maxW: wh[0], maxH: wh[1]));

            void walk(uint n, bool clipped)
            {
                const node = tree.nodes[n];
                if (node.visibility == Visibility.collapsed)
                    return;
                if (!clipped)
                    assert(frames[n].rect.right <= wh[0],
                        p.title ~ " overflows the surface sideways");
                foreach (c; node.children)
                    walk(c, clipped || node.clipX);
            }

            walk(tree.root, false);
        }
}

@("ui_gallery.gallery.aReleaseOverADifferentRowActivatesNothing")
@safe unittest
{
    // Press on one row, release on another: `PressState` refuses it, so the
    // page must not change. The classic `if (clicked && inRect)` bug.
    Gallery g;
    const page = g.s.page;
    drive(g, [
        Event(PointerEvent(action: PointerAction.press, pos: Point(3, 1))),
        Event(PointerEvent(action: PointerAction.release, pos: Point(3, 20))),
    ]);
    assert(g.s.page == page);
}

@("ui_gallery.gallery.survivesAHostileSurface")
@safe unittest
{
    // A terminal smaller than the chrome must still produce a frame rather than
    // handing the layout engine a negative extent.
    Gallery g;
    auto rec = drive(g, [keyEvent(Key.down), charEvent(']')], 20, 4);
    assert(rec.drawnFrames >= 3);
    foreach (ref f; rec.frames)
        assert(f.ops.length > 0);
}

@("ui_gallery.gallery.theToastAnimatesToItsEndAndThenStops")
@safe unittest
{
    // The recording host has a frame clock, so the notice is timed: it asks for
    // one more frame at a time and the run keeps going until it stops asking.
    // The property under test is that it DOES stop — a `requestFrame` that
    // never retires is a busy loop on the GPU target.
    Gallery g;
    auto rec = drive(g, [charEvent(']')]);

    assert(rec.frames.length > 3, "the notice animated past the script");
    assert(!rec.frames[$ - 1].requested, "and stopped asking");
    assert(!g.s.toast.visible);
}

@("ui_gallery.gallery.withoutAFrameClockTheToastWaitsForAnEvent")
@safe unittest
{
    // A terminal reports no frame time, so a timed hold would never elapse and
    // the notice would stay up forever. It holds until the next event instead —
    // the machine's own mode for a target with no clock.
    Gallery g;
    auto rec = runAppRecorded(g, RunConfig.init, [charEvent(']'), charEvent('j')],
        (ref RecordingHost h) { h.frameSeconds = 0; });

    assert(!g.s.hasFrameClock);
    assert(!g.s.toast.visible, "the following event dismissed it");
    // No frame was ever requested, so a terminal blocking on input stays
    // blocked rather than being woken by an animation it cannot run.
    foreach (ref f; rec.frames)
        assert(!f.requested);
}

@("ui_gallery.gallery.resizeReachesTheState")
@safe unittest
{
    // `HST7`: the producer's zero-size resize is filled in by the host, so the
    // shell never has to know that a terminal's resize signal carries no size.
    Gallery g;
    drive(g, [Event(ResizeEvent())], 132, 50);
    assert(g.s.surface == sizeOf(132, 50));
}

@("ui_gallery.gallery.aKeyReleaseIsNotASecondPress")
@safe unittest
{
    // A window reports releases; a terminal does not. An app switching on the
    // key alone would act twice per stroke on one target and once on the other.
    Gallery g;
    auto down = KeyEvent(Key.char_, ']');
    auto up = down;
    up.action = KeyAction.release;
    drive(g, [Event(down), Event(up)]);
    assert(g.s.themeIndex == 8, "the release did not cycle a second theme");
}
