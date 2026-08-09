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

import sparkles.input : Event, isDismiss, Key, KeyAction, KeyEvent, match,
    PointerAction, PointerEvent, ResizeEvent, WheelEvent;
import sparkles.terminal_view.cell_paint : paintCells;
import sparkles.ui.components.chrome : headerBar, scrollView;
import sparkles.ui.geometry : Constraints, Insets, Point, Rect, SizeSpec;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.scroll_view : ScrollExtents, ScrollView;
import sparkles.ui.state : hoverTargets, keyedRects, ScrollState,
    wantedPointerShape;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle, Visual;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import sparkles.ui_app.run_app : AppTheme;
import inspector : inspectorBody, inspectorInnerWidth;
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

/**
The capture-release chord: `Ctrl+]` (GS, 0x1d — a byte legacy terminal input
delivers unambiguously) or VSCode's `` Ctrl+` `` (which some terminals cannot
send at all — the reason there are two). The one binding a focused terminal
never receives.
*/
bool isCaptureRelease(in KeyEvent k) @safe pure nothrow @nogc
{
    if (k.mods.ctrl && (k.ch == '`' || k.ch == ']'
        || k.unshifted == '`' || k.unshifted == ']'))
        return true;
    // The raw GS control byte, however the input layer spelled it.
    return k.ch == '\x1d' || k.text == "\x1d";
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
        s.surface = h.size;
        s.backend = h.backend;
        s.caps = h.capabilities;

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
                if (dbgFrame == 260)
                    (() @trusted {
                        import raylib : TakeScreenshot;
                        import std.string : toStringz;

                        TakeScreenshot(shot.toStringz);
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
        const geom = contentBarGeometry();

        // Sync the machine from the measurement and clamp: a page that shrank
        // under a scrolled-down viewport must not leave the thumb past its own
        // track. `scrolledTo` is how an external move keeps the bar honest.
        s.contentView.v = s.contentView.v.scrolledTo(
            ScrollView.clampOffset(s.contentView.v.offset, geom.content,
                geom.viewport));
        // The hover-expand easing, at the shared rate. On a target with no
        // frame clock this snaps instead — see `scrollbars.easeVertical`.
        easeVertical(s.contentView, s.caps, dtMs / 1000.0f);

        const header = shellHeader(b);
        const content = contentPane(b, pageRoot, viewport, geom);

        // The inspector panel, the same shape one band over: build the body,
        // measure it, clamp the machine against the measurement, ease. Built
        // AFTER the page so its dump describes this frame's subject at this
        // frame's width.
        uint inspRoot;
        if (s.inspectorVisible)
        {
            inspRoot = inspectorBody(b, s);
            s.inspectorRows = measureHeight(b, inspRoot, inspectorInnerWidth);
            const ig = inspectorBarGeometry();
            s.inspView.v = s.inspView.v.scrolledTo(
                ScrollView.clampOffset(s.inspView.v.offset, ig.content,
                    ig.viewport));
            easeVertical(s.inspView, s.caps, dtMs / 1000.0f);
        }
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
                || easing(s.contentView, s.caps)
                || easing(s.demoView, s.caps)
                || easing(s.chromeView, s.caps)
                || easing(s.termView, s.caps)
                || easing(s.inspView, s.caps)) && s.hasFrameClock)
            h.requestFrame();

        return b.finish(root);
    }

    /// One event.
    void handle(H)(ref H h, in Event e)
    {
        e.match!(
            (in KeyEvent k) { onKey(h, k); },
            (in PointerEvent p) { onPointer(h, p); },
            (in WheelEvent w) { onWheel(w); },
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
        // With a terminal focused, the shell inside the pane owns the
        // keyboard — `q`, `Tab`, arrows, `Ctrl+C` are $(I its) keys, not the
        // gallery's, and releases forward too (the terminal-grade keyboard
        // encodes them). The release chord is the one thing the gallery
        // keeps; everything else goes to the pty. Checked before the
        // release-drop below for exactly that reason.
        if (terminalCaptures)
        {
            if (k.action != KeyAction.release && isCaptureRelease(k))
            {
                s.terms.focused = false;
                return;
            }
            // The emulator convention's scrollback keys — the second and last
            // thing the gallery keeps from a focused terminal.
            if (k.action != KeyAction.release && k.mods.shift
                && (k.key == Key.pageUp || k.key == Key.pageDown))
            {
                const page = s.terms.paneRows > 2 ? s.terms.paneRows - 1 : 1;
                return scrollTerminal(k.key == Key.pageUp ? -page : page);
            }
            if (auto tv = store.byId(s.terms.tabs[s.terms.active].id))
                cast(void) (() @trusted => tv.sendKey(k))();
            return;
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

        if (s.helpOpen)
        {
            // Modal: everything underneath is inert until it closes, so a key
            // meant for the overlay cannot also move the page behind it.
            if (isDismiss(k) || k.ch == '?' || k.ch == 'q' || k.key == Key.enter)
                s.helpOpen = false;
            return;
        }

        if (isDismiss(k) || k.ch == 'q')
            return h.quit();

        if (k.key == Key.tab)
        {
            // Two regions, so forward and backward are the same move. Shift-Tab
            // is accepted anyway, because a reader who knows the convention will
            // press it. Taken before the page sees anything: a page that could
            // claim Tab could strand a reader inside itself.
            s.region = s.region == Region.nav ? Region.content : Region.nav;
            return;
        }

        // With the keyboard in the content region the page gets first refusal —
        // which is what lets a tree own the arrow keys without the page list
        // losing them. In the nav region the shell keeps everything.
        if (s.region == Region.content
            && pages[s.page].onKey !is null && pages[s.page].onKey(s, k))
            return;

        switch (k.key)
        {
            case Key.up: return moveWithin(-1);
            case Key.down: return moveWithin(1);
            case Key.left: return setPage(s.page == 0 ? pages.length - 1 : s.page - 1);
            case Key.right: return setPage((s.page + 1) % pages.length);
            case Key.pageUp: return scrollContent(-(s.contentHeight - 1));
            case Key.pageDown: return scrollContent(s.contentHeight - 1);
            case Key.home: return scrollContent(-int.max / 4);
            case Key.end: return scrollContent(int.max / 4);
            case Key.enter: s.region = Region.content; return;
            default: break;
        }

        switch (k.ch)
        {
            case 'j': return moveWithin(1);
            case 'k': return moveWithin(-1);
            case '?': s.helpOpen = true; return;
            case ']': return cycleTheme(1);
            case '[': return cycleTheme(-1);
            case ' ': s.region = Region.content; return;
            // A punctuation key, not a letter: pages get first refusal in the
            // content region, and every plausible letter is spoken for by one
            // of them (`n`/`p` scroll, `d` discloses, `t` cycles a template).
            case '\\': s.navPinned = !s.navPinned; return;
            // The sidebar's shifted sibling, for the other side panel.
            case '|': s.inspectorOpen = !s.inspectorOpen; return;
            default: break;
        }

        // `1`..`9` then `0` jump straight to a page — the fastest route on a
        // target where the sidebar is not clickable.
        if (k.ch >= '1' && k.ch <= '9')
            return setPage(k.ch - '1');
        if (k.ch == '0')
            return setPage(9);
    }

    /// Whether the keyboard belongs to the shell inside the pane.
    private bool terminalCaptures() const @safe
        => s.page == terminalPageIndex && s.terms.focused && s.terms.any;

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
            thumb's $(B geometry) from the same cell formula the grab uses,
            because pointer events arrive in cells: the pixel formula's
            24 px minimum drew a thumb a cell longer than the grabbable
            one, and pressing that extra cell jumped the view.
    )
    */
    private void paintTermChrome(H, TV)(ref H h, TV tv, in Rect pane)
    {
        import raylib : Color, DrawRectangle;
        import sparkles.ui.state : scrollbarThumb;
        import sparkles.ui_raylib : drawScrollbar, ScrollbarLayout;

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
        const thumb = scrollbarThumb(s.terms.sbTotal, s.terms.sbLen,
            s.termView.v.offset, pane.height);
        const t = s.termView.vAnim.width - 1.0f;
        const px = cast(int)(cw * (1.0f / 3 + t * (1.5f - 1.0f / 3)));
        const w = px < 2 ? 2 : px;
        const right = (pane.x + pane.width + gutterCells) * cw;
        ScrollbarLayout l;
        l.live = true;
        l.track = Rect(right - w, pane.y * ch, w, pane.height * ch);
        l.thumb = Rect(right - w, (pane.y + thumb.start) * ch, w,
            thumb.extent * ch);
        drawScrollbar(l, s.termView.v,
            mixRgb(bg, theme().pageFg, 0.25f),
            mixRgb(bg, theme().pageFg, 0.55f));
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

    /// What the content pane's bar scrolls over, from the last measurement.
    /// One definition, because the viewport, the clamp, the thumb and the grab
    /// all read it and three of the four being right is indistinguishable from
    /// all four being right until someone drags.
    private BarGeometry contentBarGeometry() @safe
        => BarGeometry(
            content: s.contentRows,
            viewport: s.contentHeight,
            track: s.contentHeight,
        );

    /// ditto, for the inspector panel — its own document, its own numbers.
    private BarGeometry inspectorBarGeometry() @safe
        => BarGeometry(
            content: s.inspectorRows,
            viewport: s.contentHeight,
            track: s.contentHeight,
        );

    private void scrollInspector(int delta) @safe
    {
        const g = inspectorBarGeometry();
        s.inspView.wheeledV(delta,
            ScrollExtents(g.content, g.viewport, g.track));
    }

    private void scrollContent(int delta) @safe
    {
        // Through the machine, not around it: an offset moved behind the bar's
        // back leaves the thumb where it was until something else re-syncs it.
        const g = contentBarGeometry();
        s.contentView.wheeledV(delta,
            ScrollExtents(g.content, g.viewport, g.track));
    }

    private void setPage(size_t to) @safe
    {
        if (to >= pages.length || to == s.page)
            return;
        s.page = to;
        // A new page starts at its top. Carrying the previous page's offset
        // would land a short page scrolled past its own end. The bar's own
        // state — hover, animation width — is kept: the pointer has not moved.
        s.contentView.v = s.contentView.v.scrolledTo(0);
        // The inspector's dump is a new document too.
        s.inspView.v = s.inspView.v.scrolledTo(0);
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

    private void onPointer(H)(ref H h, in PointerEvent p)
    {
        // Hit targets come from the frames the painter used, so painted and
        // clickable cannot drift. Rebuilding the tree here costs one extra
        // layout per pointer event and buys the invariant outright.
        auto tree = view(h);
        auto frames = layout(tree,
            Constraints(maxW: s.surface.width, maxH: s.surface.height));
        const targets = hoverTargets(tree, frames);

        // The scrollbars first, and unconditionally. A grab owns the pointer
        // for its whole span, so the bar must see every move — including the
        // ones that stray off it, which is exactly when a bar wired only to
        // its own hover rect lets go halfway through a drag.
        if (driveVertical(s.contentView, s.capture, capContentBar, p,
                rectOf(tree, frames, hitContentBar), contentBarGeometry()))
        {
            // Consumed: a live grab is not also a press on whatever it passes
            // over. Hover still updates, so the bar stays lit while held.
            s.hover.update(p, targets);
            reportPointerShape(h);
            return;
        }

        // The inspector panel's bar, under the same rule. When the panel is
        // not showing, `rectOf` finds nothing and the geometry is not live,
        // so the call is inert rather than guarded.
        if (driveVertical(s.inspView, s.capture, capInspBar, p,
                rectOf(tree, frames, hitInspBar), inspectorBarGeometry()))
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

        // Anything else belongs to the page. The shell does not know what a
        // theme row or a tab is, and does not import a page to find out.
        if (pages[s.page].onActivate !is null && pages[s.page].onActivate(s, id))
            s.region = Region.content;
    }

    private void onWheel(in WheelEvent w) @safe
    {
        // Over the inspector panel the wheel scrolls the dump, not the page
        // it describes. The panel is the body row's rightmost child, so its
        // columns are the surface's last `inspectorWidth` — a geometric test,
        // because the wheel handler has no frames in hand (`UGL-O5`'s shape,
        // answered here for the second consumer that wanted it).
        if (s.inspectorVisible && w.pos.x >= s.surface.width - inspectorWidth)
            return scrollInspector(w.dy);

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
        // here is the bug `INP12` names.
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
        const overDivider = s.pointerAffordances && s.hover.isHot(hitSplit);
        auto want = wantedPointerShape(s.split, overDivider,
            s.contentView.v, s.demoView.v);
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
        ));
        return b.add(Widget(
            kind: WidgetKind.column,
            children: [list],
            width: SizeSpec.fixed(navWidth),
            height: SizeSpec.grow(),
            padding: Insets.symmetric(0, 1),
            clipY: true,
            key: keyNavScroll,
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
            ScrollState(s.inspView.v.offset), keyInspScroll);
        const bar = verticalBar(b, s.inspView, inspectorBarGeometry(),
            hitInspBar);
        const inner = b.add(Widget(
            kind: WidgetKind.row,
            children: [view_, bar],
        ));
        return b.add(Widget(
            kind: WidgetKind.column,
            children: [inner],
            width: SizeSpec.fixed(inspectorWidth),
            height: SizeSpec.grow(),
            padding: Insets.symmetric(0, 1),
            clipX: true,
            clipY: true,
            decoration: Decoration(
                borderWidth: Insets(0, 0, 0, 1),
                borderStyle: BorderStyle.solid,
                borderSlot: Slot.border,
            ),
        ));
    }

    private uint contentPane(ref Builder b, uint pageRoot, int viewport,
        in BarGeometry geom) @safe
    {
        const view_ = scrollView(b, pageRoot, viewport,
            ScrollState(s.contentView.v.offset), keyContentScroll);

        // The gutter is always there; only the bar inside it comes and goes. A
        // track beside content that fits says nothing, but a gutter that
        // appeared with it would reflow the whole page sideways the moment it
        // grew past the viewport (`GalleryState.contentWidth`).
        const bar = verticalBar(b, s.contentView, geom, hitContentBar);

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
        foreach (key; pages[s.page].keys)
            hints ~= b.add(Widget(kind: WidgetKind.text, text: key,
                slot: Slot.chrome));

        const help = b.add(Widget(
            kind: WidgetKind.text,
            text: "? keys   q quit",
            slot: Slot.chrome,
        ));
        return headerBar(b, hints, null, [help]);
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
        static immutable string[2][] binds = [
            ["↑ ↓ / j k", "move within the focused region"],
            ["← →", "previous / next page"],
            ["Tab", "switch between the page list and the page"],
            ["Enter / Space", "move to the page"],
            ["1 … 9, 0", "jump to a page"],
            ["PgUp / PgDn", "scroll the page"],
            ["Home / End", "top / bottom"],
            ["[ / ]", "previous / next theme"],
            ["\\", "show the page list on a narrow terminal"],
            ["|", "the inspector panel — dumpTree of the showing page"],
            ["?", "this overlay"],
            ["q / Esc", "quit"],
            ["ctrl+] / ctrl+`", "give the keyboard back to the gallery"],
            ["shift+PgUp / PgDn", "a focused terminal's scrollback"],
        ];
        foreach (ref bind; binds)
            lines ~= keyHint(b, bind[0], bind[1]);

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
    bool title, subject;
    foreach (ref n; tree.nodes)
    {
        title |= n.text == "inspector · dumpTree";
        subject |= n.text == "Primitives";
    }
    assert(title, "the panel is in the frame");
    assert(subject, "…and names the page beside it");

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
    g.s.inspView.v = g.s.inspView.v.scrolledTo(12);
    drive(g, [keyEvent(Key.right)], 120, 40);

    RecordingHost h;
    h.size = sizeOf(120, 40);
    auto tree = g.view(h);
    bool subject;
    foreach (ref n; tree.nodes)
        subject |= n.text == pages[g.s.page].title;
    assert(subject, "the dump names the page now showing");
    assert(g.s.inspView.v.offset == 0, "a new subject starts at its top");
}

@("ui_gallery.gallery.theWheelOverTheInspectorScrollsTheDumpNotThePage")
@safe unittest
{
    // The panel's columns are the surface's rightmost `inspectorWidth`; a
    // wheel there moves the dump and leaves the page alone — and vice versa.
    Gallery g;
    g.s.inspectorOpen = true;
    drive(g, [Event(WheelEvent(dy: 3, pos: Point(119, 10)))], 120, 40);
    assert(g.s.inspView.v.offset > 0, "the dump scrolled");
    assert(g.s.contentView.v.offset == 0, "the page did not");

    const dumpAt = g.s.inspView.v.offset;
    drive(g, [Event(WheelEvent(dy: 3, pos: Point(40, 10)))], 120, 40);
    assert(g.s.inspView.v.offset == dumpAt, "a wheel over the page leaves the dump");
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
    auto frames = layout(tree, Constraints(maxW: 120, maxH: 40));
    const bar = rectOf(tree, frames, hitInspBar);
    assert(bar.width > 0, "the panel's bar is in the frame");

    const press = Event(PointerEvent(action: PointerAction.press,
        button: PointerButton.left,
        pos: Point(bar.x + bar.width - 1, bar.y + bar.height / 2)));
    drive(g, [press], 120, 40);
    assert(g.s.inspView.v.dragging, "the press grabbed the bar");
    assert(g.s.inspView.v.offset > 0, "…and jumped the dump");
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
    const jumped = g.s.contentView.v.offset;
    assert(jumped > 0, "a press on the track moves the page");
    assert(g.s.contentView.v.dragging, "…and takes the grab");

    // …a drag back to the top brings it home, even though the pointer has
    // left the bar's own column entirely.
    drive(g, [Event(PointerEvent(action: PointerAction.drag,
        button: PointerButton.left, pos: Point(2, bar.y)))], 96, 24);
    assert(g.s.contentView.v.offset < jumped, "the drag tracked the pointer");

    drive(g, [Event(PointerEvent(action: PointerAction.release,
        button: PointerButton.left, pos: Point(2, bar.y)))], 96, 24);
    assert(!g.s.contentView.v.dragging);
    assert(g.s.capture.isFree, "the release freed the pointer for everything");
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
    const narrow = g.s.contentView.vAnim.width;

    auto rec = drive(g, [Event(PointerEvent(action: PointerAction.move,
        pos: Point(bar.x, bar.y + 3)))], 96, 24);

    assert(g.s.contentView.v.hovered, "the bar knows the pointer is on it");
    assert(g.s.contentView.vAnim.width > narrow, "and it is widening");
    assert(rec.frames.length > 2,
        "the run kept framing until the ease finished");
    assert(!rec.frames[$ - 1].requested, "…and then stopped");
}

@("ui_gallery.gallery.pageKeysAreGatedOnTheContentRegion")
@safe unittest
{
    import registry : pageIndexOf;

    // A page owns its keys only while the keyboard is in it. In the page list
    // the same keystroke is the shell's — which is what keeps `j`/`k` moving
    // between pages on a page whose own bindings include them.
    Gallery g;
    g.s.page = pageIndexOf("layout");
    g.s.region = Region.nav;

    drive(g, [charEvent('w')]);
    assert(g.s.layoutDemo.widthMode == 0, "the page did not see the key");

    drive(g, [keyEvent(Key.tab), charEvent('w')]);
    assert(g.s.region == Region.content);
    assert(g.s.layoutDemo.widthMode == 1, "…and now it does");
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

@("ui_gallery.gallery.captureReleaseChordSpellings")
@safe pure nothrow @nogc unittest
{
    import sparkles.input : Mods;

    // Every spelling an input layer might deliver: the two chords by ch or
    // by unshifted codepoint, and the raw GS byte legacy input decodes to.
    assert(isCaptureRelease(KeyEvent(Key.char_, ']', Mods(ctrl: true))));
    assert(isCaptureRelease(KeyEvent(Key.char_, '`', Mods(ctrl: true))));
    assert(isCaptureRelease(KeyEvent(Key.char_, '\x1d')));
    assert(!isCaptureRelease(KeyEvent(Key.char_, ']')), "a bare ] is text");
    assert(!isCaptureRelease(KeyEvent(Key.char_, 'c', Mods(ctrl: true))),
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
