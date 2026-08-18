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

    private Grid grid;
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
        changed |= pollLive();
        return changed;
    }

    /// How soon the host must wake this pane again (`Duration.max` = idle).
    /// The terminal host folds this into its input-wait deadline.
    Duration nextDeadline() @system
    {
        const now = MonoTime.currTime;
        Duration result = Duration.max;
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
        grid.resize(cast(ushort)(cols > 0 ? cols : 1),
            cast(ushort)(rows > 0 ? rows : 1));
        if (pane.themes.length == 0)
            return grid; // unwired (nothing opened yet); an empty grid
        const resized = colsShown != cols || rowsShown != rows;
        colsShown = cols;
        rowsShown = rows;
        pane.originX = 0;
        pane.resize(cols, rows);
        if (resized && shownPath.length)
            pane.relayout();
        pane.paint(grid);
        return grid;
    }

    private int colsShown, rowsShown;

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
