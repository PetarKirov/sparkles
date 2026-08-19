/**
The picker's preview pane: another instance of the document pane.

Not a stripped-down "head of the file" renderer — a real `PreviewTui` fed by
the host's own document loader, so the preview has exactly what `hue view`
has: theme-aware tree-sitter highlighting, the markdown preview, scrollbars,
diff composition, and overlays. Both hosts embed this one struct (the
terminal paints its grid directly, the window blits it through the font set),
so the pane cannot fork per backend.

What is picker-specific is the pacing, and only the pacing:

$(UL
    $(LI a selection change $(B debounces) (`loadDelay`) before loading, so
    arrowing through the list never loads every file it passes;)
    $(LI overlays whose data already ships with the document (a twoslash
    payload the loader attaches) appear immediately, but the $(B live-types
    oracle) — a `dub`-driven analyzer subprocess — only starts after the
    selection has $(B dwelt) (`overlayDelay`, default 2 s, configurable), so
    browsing stays cheap and stopping on a file is what buys the analysis.)
)
*/
module picker_preview;

import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm.searching : endsWith;

import sparkles.input.capability : cellPointer, InputCapabilities;
import sparkles.input.events : Event, KeyEvent, match, PointerAction,
    PointerEvent;
import sparkles.ui.components.scroll_view : ScrollArea, ScrollAreaAxis,
    ScrollLayout, scrollLayout;
import sparkles.ui.geometry : Rect;
import sparkles.ui.state : CaptureState;
import sparkles.ui_tui : Grid;

import document : Document;
import live_types : applyTip, LiveTypesSession;
import tui : PreviewTui;

/// The host's own document loader — the same delegate `hue view` loads with.
alias PreviewLoader = Document delegate(string path) @system;

/// ditto
struct PickerDocPane
{
    PreviewTui pane;
    PreviewLoader load;
    /// Selection-movement debounce before a load happens at all.
    Duration loadDelay = 150.msecs;
    /// Dwell before the live-types oracle starts for the shown document.
    Duration overlayDelay = 2.seconds;
    /// Master switch for the dwell-started oracle (tests turn it off).
    bool liveOverlays = true;
    /// What the host's pointer can do — feeds the bars' hover/expand easing
    /// (`IXB10`). The window host overrides with its own profile.
    InputCapabilities caps = cellPointer;

    private Grid grid;
    private CaptureState barCap;
    private MonoTime lastEase;
    private bool easeArmed;
    private bool barsEasing;
    private string wantedPath;
    private string shownPath;
    private MonoTime wantedAt;
    private MonoTime shownAt;
    private bool loadPending;
    private bool liveStarted;
    private LiveTypesSession* live;

    /// The picker's selection landed on `path` (empty = nothing selected).
    void select(string path) @system
    {
        if (path == wantedPath)
            return;
        wantedPath = path;
        wantedAt = MonoTime.currTime;
        loadPending = path.length != 0;
    }

    /// Follow the host's theme; a real change relayouts the shown document.
    void syncTheme(size_t index) @system
    {
        if (pane.themeIndex == index || index >= pane.themes.length)
            return;
        pane.setTheme(index);
        if (shownPath.length)
            pane.relayout();
    }

    /**
    Advance the debounce/dwell clocks and drain the oracle. Call once per
    frame/pass; returns whether the pane's picture changed.
    */
    bool tick() @system
    {
        bool changed;
        const now = MonoTime.currTime;
        if (loadPending && now - wantedAt >= loadDelay)
        {
            loadPending = false;
            stopLive();
            liveStarted = false;
            shownPath = null;
            if (load !is null && wantedPath.length)
            {
                Document doc;
                bool loaded;
                try
                {
                    doc = load(wantedPath);
                    loaded = true;
                }
                catch (Exception)
                {
                }
                if (loaded)
                {
                    pane.setDocument(doc.title, doc.source, doc.events,
                        doc.preview, startPreview: true, doc.twoslash,
                        doc.lang, doc.diffDoc, doc.diffSides, doc.diffSession,
                        doc.diffEmphasis);
                    shownPath = wantedPath;
                    shownAt = now;
                }
                changed = true;
            }
        }
        if (!loadPending && liveOverlays && !liveStarted && shownPath.length
            && now - shownAt >= overlayDelay)
        {
            liveStarted = true;
            startLive();
        }
        // The bars' hover/expand easing (`IXB10`) — run on the pane's OWN
        // machines (`vm.scroll`), so the hosts paint the preview's bars
        // exactly as they paint the main document pane's and the two cannot
        // look different again.
        if (easeArmed && pane.themes.length)
        {
            const vBefore = pane.vm.scroll.vAnim.percent;
            const hBefore = pane.vm.scroll.hAnim.percent;
            const dt = cast(float)((now - lastEase).total!"hnsecs")
                / 10_000_000.0f;
            pane.vm.scroll.easeV(caps, dt);
            pane.vm.scroll.easeH(caps, dt);
            barsEasing = pane.vm.scroll.vAnim.percent != vBefore
                || pane.vm.scroll.hAnim.percent != hBefore;
            changed |= barsEasing;
        }
        lastEase = now;
        easeArmed = true;
        changed |= pollLive();
        return changed;
    }

    /// How soon the host must wake this pane again (`Duration.max` = idle).
    /// The terminal host folds this into its input-wait deadline.
    Duration nextDeadline() @system
    {
        const now = MonoTime.currTime;
        Duration result = barsEasing ? 33.msecs : Duration.max;
        if (loadPending)
        {
            const elapsed = now - wantedAt;
            result = elapsed >= loadDelay ? 1.msecs : loadDelay - elapsed;
        }
        else if (liveOverlays && !liveStarted && shownPath.length)
        {
            const elapsed = now - shownAt;
            const wait = elapsed >= overlayDelay ? 1.msecs
                : overlayDelay - elapsed;
            if (wait < result)
                result = wait;
        }
        if (live !is null && 33.msecs < result)
            result = 33.msecs; // the oracle's poll cadence (`liveTick`)
        return result;
    }

    /**
    Paint into the pane's own grid at `cols`×`rows` and return it. The host
    places those cells — the terminal copies them into its frame grid, the
    window draws them through the font set — so the pane itself never needs
    a paint origin.
    */
    ref Grid paint(int cols, int rows) @system
    {
        import sparkles.ui_tui : CellStyle, Color;

        grid.resize(cast(ushort)(cols > 0 ? cols : 1),
            cast(ushort)(rows > 0 ? rows : 1));
        if (pane.themes.length == 0)
            return grid; // unwired (nothing opened yet); an empty grid
        const resized = colsShown != cols || rowsShown != rows;
        colsShown = cols;
        rowsShown = rows;
        pane.originX = 0;
        // The host owns the bar (parity with the main document pane): the
        // pane paints no bar of its own, and the last column is its
        // reserved gutter — background here, the host's bar over it.
        pane.externalScroll = true;
        const paneCols = cols > 1 ? cols - 1 : cols;
        pane.resize(paneCols, rows);
        if (resized && shownPath.length)
            pane.relayout();
        pane.paint(grid);
        if (cols > 1)
            grid.fillRect(cast(ushort)(cols - 1), 0, 1,
                cast(ushort)(rows > 0 ? rows : 1),
                CellStyle(bg: Color.fromRgb(pane.vm.pageBg)));
        return grid;
    }

    /**
    The bar geometry the hosts paint and this pane routes pointers through
    (`SCV7`) — hole-local, one derivation for both, over the pane's own
    `vm.scroll` machines. Vertical only: the preview is a glance, and its
    horizontal overflow stays on the keys (`zh`/`zl`) and the shifted wheel.
    */
    ScrollLayout bars() @system
    {
        const rows = rowsShown > 2 ? rowsShown - 2 : rowsShown;
        return scrollLayout(ScrollArea(
            rect: Rect(0, 1, colsShown, rows),
            v: ScrollAreaAxis(content: pane.docRows,
                viewport: pane.docViewRows, gutter: 1),
            h: ScrollAreaAxis(content: 0, viewport: 0, gutter: 0)));
    }

    private int colsShown, rowsShown;

    /**
    An event the picker's routing forwarded (`PKL7`) — a key while the
    preview holds the focus, or a pointer/wheel event over the hole with its
    position already pane-local. The document pane's whole input surface
    applies — scrolling, search, wrap, the `z` folds, its own scrollbar
    grabs — but host-level intents must not escape a preview. `quit` is
    swallowed (the return value is dropped) and the pane's intent flags are
    cleared, so a `<leader>ff` typed $(I into the preview) cannot re-open
    the picker.
    */
    void forward(in Event e) @system
    {
        // The bar rung first (`DCK13`'s shape): a pointer over the gutter —
        // or owned by a bar grab — drives the pane's own `vm.scroll`
        // machines through the shared step, exactly as the dock drives the
        // main pane's; everything else is the pane's.
        bool routed;
        e.match!(
            (in PointerEvent p) { routed = stepBars(p); },
            (_) {});
        if (!routed)
            cast(void) pane.handle(e);
        pane.pickerRequested = false;
        pane.inspectorToggleRequested = false;
    }

    private bool stepBars(in PointerEvent p) @system
    {
        const lay = bars();
        const overV = lay.vPointer(p).over;
        const wasGrab = pane.vm.scroll.grabbing;
        barCap = pane.vm.scroll.stepV(barCap, 1, p, pane.vm.top, lay);
        if (p.action == PointerAction.release)
            barCap = barCap.released(); // the central release (`STM11`)
        pane.vm.top = pane.vm.scroll.v.offset;
        return overV || wasGrab || pane.vm.scroll.grabbing;
    }

    /// ditto
    void forwardKey(in KeyEvent k) @system
    {
        forward(Event(k));
    }

    /// The picker closed: stop the oracle, keep the document (a reopen on
    /// the same selection shows instantly).
    void close() @system
    {
        loadPending = false;
        stopLive();
        liveStarted = false;
    }

    /// ditto — and the host is exiting.
    void shutdown() @system
    {
        close();
    }

private:
    // The same shape the workspace runs for its main pane (`PRJ12`), minus
    // the diff-side oracles: one session for the shown document, silenced
    // stderr, dropped on failure without a notice — a preview must never
    // interrupt the host to explain itself.
    void startLive() @system
    {
        if (!shownPath.endsWith(".d") || pane.twoslashPayload.code.length)
            return;
        string reason;
        live = LiveTypesSession.start(shownPath, reason,
            silenceChildStderr: true);
    }

    void stopLive() @system
    {
        if (live is null)
            return;
        live.shutdown();
        live = null;
    }

    bool pollLive() @system
    {
        if (live is null)
            return false;
        bool changed;
        live.poll();
        if (live.payloadReady)
        {
            pane.attachTwoslash(live.takePayload());
            changed = true;
        }
        foreach (answer; live.takeAnswers())
            changed |= applyTip(pane.twoslashPayload, answer);
        if (live.failed)
            stopLive();
        return changed;
    }
}

@("picker.preview.debounceLoadsOnlyTheDwelledSelection")
@system
unittest
{
    import core.time : Duration;
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet, Theme;

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];

    PickerDocPane preview;
    preview.liveOverlays = false;
    preview.loadDelay = Duration.zero;
    preview.pane.names = names[];
    preview.pane.themes = themes[];
    preview.pane.labels = LabelSet.standard();

    string[] loads;
    preview.load = delegate Document(string path) @system {
        loads ~= path;
        Document doc;
        doc.title = path;
        doc.source = "int x;\n";
        doc.events = [HighlightEvent.sourceSpan(0, doc.source.length)];
        return doc;
    };

    // Same selection twice: one load. A zero debounce loads on the next tick.
    preview.select("a.d");
    preview.select("a.d");
    assert(preview.tick());
    assert(loads == ["a.d"]);
    assert(!preview.tick(), "an unchanged selection re-loads nothing");

    // The pane paints its document into its own grid at any size.
    auto g = &preview.paint(40, 8);
    string all;
    foreach (y; 0 .. g.rows)
        foreach (x; 0 .. g.cols)
            all ~= (*g)[cast(ushort) x, cast(ushort) y].grapheme;
    import std.algorithm.searching : canFind;

    assert(all.canFind("int x;"), all);

    preview.select("b.d");
    assert(preview.tick());
    assert(loads == ["a.d", "b.d"]);
    preview.shutdown();
}

@("picker.preview.hostOwnedBarsDriveThePane")
@system
unittest
{
    import core.time : Duration;
    import sparkles.input.events : PointerButton;
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet, Theme;
    import sparkles.ui.geometry : Point;

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];

    PickerDocPane preview;
    preview.liveOverlays = false;
    preview.loadDelay = Duration.zero;
    preview.pane.names = names[];
    preview.pane.themes = themes[];
    preview.pane.labels = LabelSet.standard();
    preview.load = delegate Document(string path) @system {
        Document doc;
        doc.title = path;
        foreach (i; 0 .. 40)
            doc.source ~= "int line;\n";
        doc.events = [HighlightEvent.sourceSpan(0, doc.source.length)];
        return doc;
    };
    preview.select("long.d");
    assert(preview.tick());
    cast(void) preview.paint(40, 12);

    // The bar geometry is host-shared and hole-local: the reserved gutter is
    // the last column, spanning the body rows.
    const lay = preview.bars;
    assert(lay.vLive, "an overflowing document has a live bar");
    assert(lay.vTrack == Rect(39, 1, 1, 10));

    // A press on the thumb and a drag scroll the DOCUMENT, through the
    // pane's own `vm.scroll` machine — the same one the main document pane
    // runs, which is the whole parity point.
    const before = preview.pane.vm.top;
    preview.forward(Event(PointerEvent(pos: Point(39, 1),
        action: PointerAction.press, button: PointerButton.left)));
    assert(preview.pane.vm.scroll.grabbing, "a thumb press grabs");
    preview.forward(Event(PointerEvent(pos: Point(39, 6),
        action: PointerAction.drag, button: PointerButton.left)));
    assert(preview.pane.vm.top > before, "a bar drag scrolls the document");
    preview.forward(Event(PointerEvent(pos: Point(39, 6),
        action: PointerAction.release, button: PointerButton.left)));
    assert(!preview.pane.vm.scroll.grabbing, "the release ends the grab");

    // The easing clock runs on the pane's own anim machines, so the hosts
    // can paint the same hover/expand animation the document pane has.
    preview.pane.vm.scroll.v = preview.pane.vm.scroll.v.hoveredNow(true);
    cast(void) preview.tick(); // arms the clock
    import core.thread : Thread;
    import core.time : msecs;

    Thread.sleep(20.msecs);
    cast(void) preview.tick();
    assert(preview.pane.vm.scroll.vAnim.percent > 0,
        "the hover expansion eases");
    preview.shutdown();
}
