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
import sparkles.ui.components.chrome : headerBar, scrollbar, scrollView;
import sparkles.ui.geometry : Constraints, Insets, Point, SizeSpec;
import sparkles.ui.layout : layout;
import sparkles.ui.state : hoverTargets;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import compat : AppTheme;
import kit;
import pages.themes_page : themeAt;
import registry : pages;
import state;

// No module-level `@safe:` here, deliberately. `view` and `handle` are member
// templates instantiated against every host, and the GPU host's `size` and
// `frameSeconds` are `@system` — forcing `@safe` on the templates would reject
// the very backend the gallery exists to run on. The attributes infer, exactly
// as they do for `isCanvas` and `isHost`; the pure view helpers below, being
// non-templates, are annotated by hand.
//
// The theme accessor is `@safe` because `runApp` probes for it from a context
// that may be either.

/// ditto
struct Gallery
{
    /// Everything the gallery knows.
    GalleryState s;

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

        auto b = Builder();

        // The page first, so its natural height is known before the scroll
        // view that clips it is built — one measurement, shared by the
        // viewport, the clamp and the scrollbar, so the three cannot disagree.
        const pageRoot = pages[s.page].view(b, s);
        const contentRows = measureHeight(b, pageRoot, s.contentWidth);
        const viewport = s.contentHeight;
        s.contentScroll = s.contentScroll.scrolledBy(0, contentRows, viewport);

        const header = shellHeader(b);
        const content = contentPane(b, pageRoot, contentRows, viewport);

        // On a narrow surface the list yields its width rather than squeezing
        // the catalog into a third of the screen. `collapsed`, not `hidden`:
        // hidden would keep the 22 cells and give the page nothing.
        uint[] bodyChildren;
        if (s.navVisible)
            bodyChildren ~= navPane(b);
        bodyChildren ~= content;

        const body_ = b.add(Widget(
            kind: WidgetKind.row,
            children: bodyChildren,
            gap: s.navVisible ? 1 : 0,
            height: SizeSpec.grow(),
        ));
        const footer = statusBar(b);

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
        if (s.toast.visible && s.hasFrameClock)
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

    // ── keyboard ────────────────────────────────────────────────────────────

    private void onKey(H)(ref H h, in KeyEvent k)
    {
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

        switch (k.key)
        {
            case Key.tab:
                // Two regions, so forward and backward are the same move.
                // Shift-Tab is accepted anyway, because a reader who knows the
                // convention will press it.
                s.region = s.region == Region.nav ? Region.content : Region.nav;
                return;
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
            case 'n': s.navPinned = !s.navPinned; return;
            default: break;
        }

        // The page's own bindings come after the shell's, never before: a page
        // that saw input first could claim `j` and strand a reader on it.
        if (pages[s.page].onKey !is null && pages[s.page].onKey(s, k.ch))
            return;

        // `1`..`9` then `0` jump straight to a page — the fastest route on a
        // target where the sidebar is not clickable.
        if (k.ch >= '1' && k.ch <= '9')
            return setPage(k.ch - '1');
        if (k.ch == '0')
            return setPage(9);
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

    private void scrollContent(int delta) @safe
    {
        // Clamped against the last measured content height, which `view` keeps
        // current — the same number the scrollbar's thumb comes from.
        s.contentScroll = s.contentScroll.scrolledBy(delta,
            s.contentScroll.offset + s.contentHeight + measuredOverflow,
            s.contentHeight);
    }

    private void setPage(size_t to) @safe
    {
        if (to >= pages.length || to == s.page)
            return;
        s.lastPage = s.page;
        s.page = to;
        // A new page starts at its top. Carrying the previous page's offset
        // would land a short page scrolled past its own end.
        s.contentScroll = typeof(s.contentScroll).init;
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
        const targets = hoverTargets(tree, layout(tree,
            Constraints(maxW: s.surface.width, maxH: s.surface.height)));

        final switch (p.action)
        {
            case PointerAction.move:
            case PointerAction.drag:
                s.hover.update(p, targets);
                return;
            case PointerAction.leave:
                s.hover.update(p, targets);
                s.press = s.press.cancelled;
                return;
            case PointerAction.press:
                s.hover.update(p, targets);
                s.press = s.press.pressed(s.hover.hot);
                return;
            case PointerAction.release:
                s.hover.update(p, targets);
                s.press = s.press.released(s.hover.hot);
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

        if (id >= hitNav && id < hitNav + pages.length)
        {
            s.region = Region.nav;
            return setPage(id - hitNav);
        }

        const theme = themeAt(id);
        if (theme != size_t.max)
            return selectTheme(theme);
    }

    private void onWheel(in WheelEvent w) @safe
    {
        // The producer already multiplied by `linesPerNotch`; multiplying again
        // here is the bug `INP12` names.
        scrollContent(w.dy);
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
        return headerBar(b, [title, blurb], centre, [themeTag]);
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

    private uint contentPane(ref Builder b, uint pageRoot, int contentRows,
        int viewport) @safe
    {
        const view_ = scrollView(b, pageRoot, viewport, s.contentScroll,
            keyContentScroll);

        // The gutter is always there; only the bar inside it comes and goes. A
        // track beside content that fits says nothing, but a gutter that
        // appeared with it would reflow the whole page sideways the moment it
        // grew past the viewport (`GalleryState.contentWidth`).
        const bar = contentRows > viewport
            ? scrollbar(b, contentRows, viewport, s.contentScroll.offset, viewport)
            : b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(1)));

        return b.add(Widget(
            kind: WidgetKind.row,
            children: [view_, bar],
            width: SizeSpec.grow(),
            height: SizeSpec.grow(),
            gap: 1,
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
            ["?", "this overlay"],
            ["q / Esc", "quit"],
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

    /// How far the content extends past the viewport, from the last frame's
    /// measurement. Kept as a field rather than recomputed, because a key
    /// handler has no builder and clamping is the one thing it needs it for.
    private int measuredOverflow;

    private int measureHeight(ref Builder b, uint root, int width) @safe
    {
        // A throwaway layout of the page subtree alone. It is the same engine
        // and the same constraints the real pass uses, so the number is the one
        // the frame will actually have — not an estimate the scrollbar would
        // then contradict.
        auto probe = WidgetTree(b.nodes, root);
        const rows = layout(probe, Constraints(maxW: width))[root].rect.height;
        measuredOverflow = rows > s.contentHeight ? rows - s.contentHeight : 0;
        return rows;
    }
}

private auto rgbOr(C)(in C c, ubyte r, ubyte g, ubyte bl) @safe
{
    import sparkles.base.term_color : Color, RgbColor;

    return c.kind == Color.Kind.rgb ? c.rgb : RgbColor(r, g, bl);
}

// ---------------------------------------------------------------------------
// Tests — the whole shell, headless, through the recording host.
// ---------------------------------------------------------------------------

version (unittest)
{
    import compat : RecordingHost, runAppRecorded;
    import sparkles.input : charEvent, keyEvent, Mods;
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
    import compat : isAppFor, RecordingHost;

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
