/**
The picker's host glue, shared by the window and the terminal workspace.

`picker` owns the presentation-free state and the generation scheduler;
`picker_view` owns the widget tree; `picker_sources` owns the corpus. What a
host still needed was the plumbing between them — open/close, the modal key
policy, the per-frame poll, and the accept handshake — and writing it twice
is how the two backends would have drifted. Painting stays host-specific
(each interprets the shared widget tree through its own canvas); everything
that decides stays here.
*/
module picker_host;

import core.time : Duration, msecs;

import sparkles.base.unique : makeUnique, Unique;
import sparkles.event_horizon.raw_pool : RawPoolResult;
import sparkles.fuzzy : CandidateSnapshot, DefaultFuzzyCaps, FuzzyLimits,
    Location, MatchConfig, MatcherWorkspace, parseQuery, positions,
    RankedResult, TextRange;
import sparkles.input.capability : cellPointer, InputCapabilities;
import sparkles.input.events : Event, Key, KeyEvent, match, PointerAction,
    PointerButton, PointerEvent, WheelEvent;
import sparkles.ui.focus : ScopeFocus;
import sparkles.ui.geometry : Constraints, Point, Rect;
import core.time : MonoTime;

import sparkles.ui.layout : Frame, layout;
import sparkles.ui.widget : WidgetTree;

import keymap : Command, commandFor, KeyContext, Scope_;
import picker : PickerScheduler, PickerState;
import sparkles.source_view.search : SearchPolicy;

import picker_grep : GrepFinder, modeLabel, PickerSource, ScanStep;
import picker_sources : collectFilesFinder, FilesFinder, PickerTarget;
import sparkles.ui.components.scroll_view : ScrollArea, ScrollAreaAxis,
    scrollLayout;
import sparkles.ui.state : CaptureState;

import picker_view : GrepRowText, pickerHBarHitId, pickerListBox,
    pickerVBarHitId,
    pickerMaxPanelRows;
import picker_view : PickerGeometry, PickerLayout, pickerPreviewRect,
    pickerView, RowHighlight;

/// What a modal event did — the host acts on `accepted` (open the file),
/// hands `previewEvent` to the preview document pane on `preview`, and
/// repaints on the rest.
enum PickerAction : ubyte
{
    consumed, /// state changed (or the event was swallowed); still open
    closed,   /// the picker dismissed itself
    accepted, /// a row was accepted — `acceptedTarget` names where to go
    preview,  /// forward `previewEvent` to the preview document pane
}

/**
The most rows the list can paint at once — an array bound, not a policy.

The ACTUAL viewport is `pickerListBox(geometry).rows`, which follows the
panel. This is only the compile-time ceiling the per-row highlight arrays are
sized to, so it must cover the tallest panel `pickerMaxPanelRows` allows
minus its chrome. It was 16, which is why a forty-row panel painted sixteen
rows and left the rest empty.
*/
enum size_t pickerVisibleRows = pickerMaxPanelRows;

/// Ranked results the picker KEEPS — deeper than the viewport, so the list
/// scrolls through the ranking instead of the ranking being truncated to
/// whatever fits.
///
/// These were one number while every source was a file picker, where typing
/// refines faster than scrolling and a handful of top hits answer the
/// question. Grep does not behave that way: the wanted hit is routinely
/// past the first screen, and a query that cannot be narrowed further
/// (`PKC17`'s literal needle) leaves scrolling as the only move.
enum size_t pickerTopK = 128;

/**
A host's picker, owned off the collected heap.

A `PickerHost` is a few megabytes — four generation slots of matcher
workspace plus one for render-time positions — and asking the collector for a
block that size crashes inside its stack scan on macOS when the requesting
thread is not the main one (a test runs on a `std.parallelism` worker, whose
stack is 512 KiB there). `Unique` allocates it with `malloc` instead, and
registers the block as a root range so the paths the finder owns stay
reachable.
*/
alias OwnedPicker = Unique!PickerHost;

/**
One host-owned picker: corpus, scheduler, state, and the modal key policy.

Non-copyable (the scheduler's generation slots are address-stable), so hosts
hold an $(LREF OwnedPicker) built on first open — a user action, under hue's
startup/shutdown allocation carve-out (`NFR1`). `shutdown` must run before
the host exits; it stops the worker pool.
*/
struct PickerHost
{
    @disable this(this);

    PickerState!pickerTopK state;
    PickerScheduler!(DefaultFuzzyCaps, pickerTopK) scheduler;
    FilesFinder finder;
    /**
    The content-search corpus, live when `source == PickerSource.grep`.

    Held BESIDE the files finder rather than selected by templating
    `PickerHost` on its source: the scheduler's generation slots are
    megabytes of workspace, and a template would duplicate them once per
    source. Dispatch is a `final switch`, so the compiler proves every arm
    is answered.
    */
    GrepFinder grep;
    /// Which corpus the open picker is showing.
    PickerSource source;
    /// Set by `handleKey` when it returns `PickerAction.accepted`.
    /// Where the accepted row goes (`PKC3`): a path when the source is
    /// file-backed, plus a line/column when the source has a position to
    /// name. `acceptedPath` remains as the file-only view of it.
    PickerTarget acceptedTarget;
    /// ditto — the path half, for hosts that only open files.
    string acceptedPath() const @safe pure nothrow @nogc
        => acceptedTarget.path;
    /// Which picker pane owns the keyboard (`FOC2`/`PKL7`) — the value
    /// `KeyContext.pickerFocus` carries into resolution, and the view reads
    /// for its chrome. Reset to the prompt on every open.
    ScopeFocus!Scope_ focus = ScopeFocus!Scope_(Scope_.pickerInput);
    /// Set when `handleKey`/`handleOverlay` return `PickerAction.preview`:
    /// the event the host must hand the preview document pane, with any
    /// position already pane-local.
    Event previewEvent;

    /// A press inside the preview hole grabs the pointer for the pane
    /// (`STM11`): drags and the release forward wherever they stray, so its
    /// scrollbar grabs survive leaving the hole.
    private bool previewGrab;

    /**
    Ease the list bar's expansion (`IXB10`).

    The bar had a live `hovered` flag and an `hAnim` that nothing ever
    stepped, so it painted at a constant width: the hover expansion existed
    in the state and never on screen. This is the pane's own easing, run on
    the same `ScrollView` the preview eases its bars with, so the two look
    alike rather than one animating and the other not.
    */
    private bool easeBars() @system
    {
        import core.time : MonoTime;

        if (!state.active)
            return false;
        const now = MonoTime.currTime;
        scope (exit) lastEase = now;
        if (!easeArmed)
        {
            easeArmed = true;
            return false;
        }
        const before = state.scroll.hAnim.percent;
        const dt = cast(float)((now - lastEase).total!"hnsecs") / 10_000_000.0f;
        state.scroll.easeH(caps, dt);
        return state.scroll.hAnim.percent != before;
    }

    private MonoTime lastEase;
    private bool easeArmed;

    /// What the host's pointer can do — feeds the bar's hover easing.
    InputCapabilities caps = cellPointer;

    /// Capture for the list's horizontal bar (`STM11`). A grab owns the
    /// pointer until release, so a drag that strays off the track keeps
    /// scrolling rather than falling into the row-selection arm.
    private CaptureState barCap;

    /// The capture id the list's bar arbitrates under — distinct from the
    /// preview pane's, which runs its own.
    private enum size_t listBarCapId = 2;
    /// ditto, for the vertical bar — a distinct id so the two arbitrate
    /// separately and a grab on one never claims the other.
    private enum size_t listVBarCapId = 3;

    /// The pane order `Tab` cycles (`pickerFocusNext`/`Prev`).
    static immutable Scope_[3] paneOrder =
        [Scope_.pickerInput, Scope_.pickerList, Scope_.pickerPreview];

    private alias Pool = typeof(scheduler).Pool;
    private Pool pool;
    private bool poolLive;
    private bool poolTried;

    // Render-time decor, refreshed when the rows change: fuzzy-match byte
    // ranges per visible row (the positions-on-demand doctrine — never
    // stored on results), and the resolved selected path the hosts feed
    // their preview document pane with.
    private MatcherWorkspace!DefaultFuzzyCaps positionsWorkspace;
    // Indexed by PAINTED row, not by ranked row: highlights are only worth
    // deriving for what the reader can see, and with the kept top-K deeper
    // than the viewport, deriving all of them would run the positions tier
    // over rows nobody is looking at.
    private TextRange[maxRowRanges][pickerVisibleRows] rowRanges;
    private size_t[pickerVisibleRows] rowRangeCounts;
    private size_t selectedIndex_ = size_t.max;
    private string selectedPath_;

    private enum size_t maxRowRanges = 8;

    /// One duration-bounded search step per request/poll (`PIK5`);
    /// config-owned (`picker.stepBudgetMs`), seeded with the historical 4.
    Duration stepBudget = 4.msecs;

    /**
    Re-walk `root` (fresh corpus — the picker must see files created since
    the last open), reset the prompt, and rank the whole corpus under the
    empty query. The walk is the documented synchronous seam of `PKS1`;
    the streaming walk is later picker work.
    */
    void open(string root, const(string)[] includeGlobs = null,
        const(string)[] excludeGlobs = null) @system
    {
        source = PickerSource.files;
        if (!poolTried)
        {
            // One worker: the search is chunked and cancellable, and the UI
            // thread only ever polls. Startup failure is the documented
            // degradation (`PIK8`) — every step then runs synchronously
            // inside `poll`, budget-bounded.
            poolTried = true;
            poolLive = Pool.start(pool, 1) == RawPoolResult.accepted;
            if (poolLive)
                scheduler.attach(pool);
        }
        scheduler.cancel(); // running generations retire against the old corpus
        finder = collectFilesFinder(root, includeGlobs, excludeGlobs);
        state.viewRows = pickerVisibleRows; // paint 16, keep `pickerTopK`
        state.open();
        focus = ScopeFocus!Scope_(Scope_.pickerInput);
        selectedIndex_ = size_t.max;
        selectedPath_ = null;
        refreshHighlights();
        request();
    }

    /**
    Open the **grep** source over `root` (`PKS2`).

    Same shape as `open`, and deliberately a separate entry point rather
    than a flag: the two sources disagree about what a generation IS — the
    files corpus is walked once and searched repeatedly, while grep re-walks
    nothing and re-reads per query — so sharing one function would mean a
    branch in every line of it.
    */
    void openGrep(string root, const(string)[] includeGlobs = null,
        const(string)[] excludeGlobs = null) @system
    {
        source = PickerSource.grep;
        scheduler.cancel(); // the fuzzy scheduler owns nothing here
        grep.openCorpus(root, includeGlobs, excludeGlobs);
        state.viewRows = pickerVisibleRows;
        state.open();
        focus = ScopeFocus!Scope_(Scope_.pickerInput);
        selectedIndex_ = size_t.max;
        selectedPath_ = null;
        rowRangeCounts[] = 0;
        request();
    }

    /// ditto
    void close() @safe nothrow @nogc
    {
        state.close();
        scheduler.cancel();
    }

    /// Stops the worker pool. Call once, when the host exits.
    void shutdown() @system
    {
        close();
        if (poolLive)
        {
            cast(void) pool.shutdown(true);
            poolLive = false;
        }
    }

    /// The immutable corpus generation the rows index into — the same value
    /// the scheduler searches, so the view cannot resolve rows against a
    /// different snapshot.
    CandidateSnapshot snapshot() const @trusted pure nothrow @nogc
    {
        // A grep row resolves through `GrepFinder`, not through a candidate
        // snapshot — its rows are lines, and a snapshot describes paths.
        // The view reads `grepRows` for those, and never indexes this.
        final switch (source)
        {
        case PickerSource.files: return finder.snapshot();
        case PickerSource.grep: return CandidateSnapshot.init;
        }
    }

    /// Whether the loop must keep ticking to make progress (a running or
    /// pending generation) rather than blocking on input.
    bool busy() const @safe nothrow @nogc
        => state.active && (state.searching || scheduler.hasInFlight
            || grep.searching);

    /// Documents scanned per frame in grep mode. A budget in FILES rather
    /// than milliseconds: the scan is clock-free so it can run on the pool,
    /// and the host already ticks once per frame.
    enum size_t grepDocsPerFrame = 64;

    /// The case rule both the viewer and the picker obey (`FND`).
    SearchPolicy searchPolicy;

    /**
    Dispatch completions and publish the newest partial page. Call once per
    frame/pass; returns whether anything the host renders changed.
    */
    bool poll() @system
    {
        if (!state.active && !scheduler.hasInFlight)
            return false;
        const before = fingerprint();
        final switch (source)
        {
        case PickerSource.files:
            scheduler.poll(state);
            break;
        case PickerSource.grep:
            // One frame's worth of documents, then publish what is admitted
            // so far — the list grows rather than appearing all at once.
            if (grep.searching)
            {
                cast(void) grep.step(grepDocsPerFrame);
                publishGrep();
            }
            break;
        }
        const changed = fingerprint() != before;
        if (changed)
            refreshHighlights();
        return changed || easeBars();
    }

    /// The selected row's resolved absolute path (null when nothing is
    /// selected) — what the hosts feed their preview document pane.
    string selectedPath() @system
    {
        const index = state.selectedCorpusIndex;
        if (index != selectedIndex_)
        {
            selectedIndex_ = index;
            final switch (source)
            {
            case PickerSource.files:
                selectedPath_ = finder.resolve(index).path;
                break;
            case PickerSource.grep:
                selectedPath_ = grep.resolve(index).path;
                break;
            }
        }
        return selectedPath_;
    }

    /**
    Build this frame's widget tree — the shared view plus the host-derived
    decor (match highlights, the preview panel's heading). Both canvases
    interpret one tree, so the two backends cannot drift.
    */
    WidgetTree buildView(PickerGeometry geometry,
        PickerLayout preset = PickerLayout.default_) @system
    {
        import std.path : baseName;

        RowHighlight[pickerVisibleRows] highlights;
        const shown = state.visible.length;
        foreach (i; 0 .. shown)
            highlights[i] = RowHighlight(rowRanges[i][0 .. rowRangeCounts[i]]);
        const path = selectedPath();

        // Grep rows and their mode indicator, for the grep source only. The
        // view takes plain data, so it never learns what a scanner is.
        GrepRowText[pickerVisibleRows] rows;
        const(char)[] mode;
        final switch (source)
        {
        case PickerSource.files:
            break;
        case PickerSource.grep:
            foreach (i, ranked; state.visible)
                rows[i] = grep.rowText(ranked.corpusIndex);
            mode = modeLabel(grep.grepMode);
            break;
        }

        // Both viewports from ONE derivation of the panel's content box.
        // They were a constant 16 rows and a `panelCols - 2` guess before:
        // the list painted sixteen rows however tall the panel grew, and
        // the horizontal scroll stopped two columns short of the longest
        // row because the guess forgot one of the two padding columns.
        const listBox = pickerListBox(geometry);
        state.viewCols = listBox.cols;
        state.viewRows = listBox.rows > pickerVisibleRows
            ? pickerVisibleRows : listBox.rows;
        auto tree = pickerView(state, snapshot,
            highlights[0 .. shown],
            path.length ? baseName(path) : null, geometry, preset,
            focus.focused,
            source == PickerSource.grep ? rows[0 .. shown] : null, mode);

        // The list's extent, measured off the tree that was just built
        // rather than re-derived — the rendered spans ARE the row, so
        // nothing can drift between what is painted and what the bar
        // describes. Rows are trimmed by exactly `hOffset` cells, so adding
        // it back recovers the untrimmed width of the widest one.
        {
            import sparkles.source_view.search : columnWidth;
            import sparkles.ui.widget : WidgetKind;

            size_t widest;
            foreach (ref const node; tree.nodes)
            {
                if (node.kind != WidgetKind.rich)
                    continue;
                size_t w;
                foreach (ref const sp; node.spans)
                    w += columnWidth(sp.text);
                if (w > widest)
                    widest = w;
            }
            state.contentCols = widest == 0 ? 0 : widest + state.hOffset;
        }
        return tree;
    }

    /// The `:line[:col]` suffix the prompt currently carries (`PKQ4`), or
    /// an absent `Location`. Parsed on acceptance only — never per
    /// keystroke, where the search path already parses the query.
    private Location promptLocation() @system
    {
        auto parsed = parseQuery(state.prompt.text);
        return parsed.hasError ? Location.init : parsed.value.location;
    }

    /// The resolution context the picker's keys live in: the modal flag plus
    /// the focused pane (`FOC4` — modality is context gating).
    KeyContext keyContext() const @safe pure nothrow @nogc
        => KeyContext(pickerActive: true, pickerFocus: focus.focused,
            grepActive: source == PickerSource.grep);

    /**
    The modal key policy, identical in both hosts — and, since `PKL7`, table
    rows rather than a hand-written waterfall: the `picker*` scopes of
    `hueBindings` resolve the chords, the focused pane selects which rows are
    reachable, and this dispatch only answers the picker's own commands.

    The fallback rung (`FOC4`) is what an $(I unbound) key means per pane:
    prompt text in the input pane, a refocus-and-type from the list (a
    printable is always a query edit — snacks.picker's affordance), and a
    forwarded key in the preview, where the document pane's whole keymap
    (scrolling, search, wrap) applies unmodified. Every key is consumed
    while the picker is open — it is a modal surface (`PIK1`).
    */
    PickerAction handleKey(in KeyEvent k) @system
    {
        switch (commandFor(k, keyContext()).cmd)
        {
        case Command.pickerClose:
            close();
            return PickerAction.closed;
        case Command.pickerAccept:
            const index = state.selectedCorpusIndex;
            auto target = resolveRow(index);
            if (!target.valid)
                return PickerAction.consumed; // nothing to accept yet
            // `PKQ4`: the query language has always parsed a trailing
            // `:line[:col]`, and nothing consumed it — pasting
            // `src/app.d:120` from a compiler diagnostic narrowed the list
            // and then opened at the top of the file. A position the row
            // already carries wins, since a grep hit knows better than the
            // prompt where it is.
            if (target.line == 0)
            {
                const loc = promptLocation();
                if (loc.present)
                {
                    target.line = loc.startLine;
                    target.column = loc.hasColumn ? loc.startColumn : 0;
                }
            }
            acceptedTarget = target;
            close();
            return PickerAction.accepted;
        case Command.pickerScrollLeft:
        case Command.pickerScrollRight:
            // `PKL8`. Eight cells a step: one is too slow across a deep
            // path, and a whole panel loses the reader's place.
            cast(void) state.scrollHorizontal(
                commandFor(k, keyContext()).cmd == Command.pickerScrollLeft
                    ? -8 : 8);
            return PickerAction.consumed;
        case Command.pickerCycleMode:
            // `PKL5`. Gated to the grep source by `CtxFlag.grepActive`, so
            // the same chord still reverses the pane focus everywhere else
            // and the guide lists whichever one applies.
            grep.cycleMode();
            request();
            return PickerAction.consumed;
        case Command.pickerErase:
            if (state.prompt.erase())
                request();
            return PickerAction.consumed;
        case Command.pickerUp:
            state.moveSelection(-1);
            return PickerAction.consumed;
        case Command.pickerDown:
            state.moveSelection(1);
            return PickerAction.consumed;
        case Command.pickerPageUp:
            state.moveSelection(-cast(long) pickerVisibleRows / 2);
            return PickerAction.consumed;
        case Command.pickerPageDown:
            state.moveSelection(pickerVisibleRows / 2);
            return PickerAction.consumed;
        case Command.pickerTop:
            state.moveSelection(-cast(long) state.rowCount);
            return PickerAction.consumed;
        case Command.pickerBottom:
            state.moveSelection(state.rowCount);
            return PickerAction.consumed;
        case Command.pickerFocusNext:
            focus = focus.cycled(paneOrder[], 1);
            return PickerAction.consumed;
        case Command.pickerFocusPrev:
            focus = focus.cycled(paneOrder[], -1);
            return PickerAction.consumed;
        case Command.pickerToggleScore:
            state.toggleScoreDebug();
            return PickerAction.consumed;
        case Command.pickerPreviewDown:
            previewEvent = Event(KeyEvent(key: Key.pageDown));
            return PickerAction.preview;
        case Command.pickerPreviewUp:
            previewEvent = Event(KeyEvent(key: Key.pageUp));
            return PickerAction.preview;
        default:
            break; // unbound here — the pane fallback below
        }
        if (focus.isFocused(Scope_.pickerPreview))
        {
            previewEvent = Event(k);
            return PickerAction.preview;
        }
        if (k.key == Key.char_ && !k.mods.ctrl && !k.mods.alt && k.ch >= 0x20)
        {
            // A printable refocuses the prompt (the list never swallows a
            // query edit) and types.
            focus = ScopeFocus!Scope_(Scope_.pickerInput);
            if (state.prompt.type(k.ch))
                request();
        }
        return PickerAction.consumed;
    }

    /**
    Route a pointer or wheel event whose position is $(B overlay-local) — in
    cells, relative to the overlay's top-left corner (the hosts translate
    from their own screen space). The `DCK7` doctrine, inside the modal: the
    wheel scrolls the element $(I under the cursor) — the list moves its
    selection, the preview scrolls its document — never a pane beneath the
    overlay. A press selects the row it lands on (and focuses the list), or
    focuses the preview and forwards, so the document pane's own scrollbars
    are draggable.

    Hit geometry is derived from the same tree the hosts paint
    (`buildView` + `layout`), never registered — `INP10`.
    */
    PickerAction handleOverlay(in Event e, PickerGeometry geometry) @system
    {
        auto tree = buildView(geometry);
        auto frames = layout(tree, Constraints(maxW: 2 * geometry.panelCols));
        const hole = pickerPreviewRect(tree, frames);

        PickerAction result = PickerAction.consumed;
        e.match!(
            (in WheelEvent w) {
                if (hole.contains(w.pos))
                {
                    WheelEvent local = w;
                    local.pos = Point(w.pos.x - hole.x, w.pos.y - hole.y);
                    previewEvent = Event(local);
                    result = PickerAction.preview;
                    return;
                }
                if (w.pos.x < geometry.panelCols)
                    state.moveSelection(w.dy); // web sign: positive is down
            },
            (in PointerEvent p) {
                // An active preview grab keeps every motion (`STM11`),
                // wherever the pointer strays; the release ends it.
                const press = p.action == PointerAction.press
                    && p.button == PointerButton.left;
                if (previewGrab || (press && hole.contains(p.pos)))
                {
                    if (press)
                    {
                        previewGrab = true;
                        focus = ScopeFocus!Scope_(Scope_.pickerPreview);
                    }
                    if (p.action == PointerAction.release)
                        previewGrab = false;
                    PointerEvent local = p;
                    local.pos = Point(p.pos.x - hole.x, p.pos.y - hole.y);
                    previewEvent = Event(local);
                    result = PickerAction.preview;
                    return;
                }
                // Bare motion over the hole forwards too (pane-local, no
                // focus change), so the pane's hover affordances — its
                // scrollbar's hot/expand feedback — work under the overlay.
                if (p.action == PointerAction.move && hole.contains(p.pos))
                {
                    PointerEvent local = p;
                    local.pos = Point(p.pos.x - hole.x, p.pos.y - hole.y);
                    previewEvent = Event(local);
                    result = PickerAction.preview;
                    return;
                }
                // The bar rung first (`DCK13`'s shape, and the same order
                // `picker_preview` uses for the preview's own bars): a
                // pointer on the track — or owned by a live grab — drives
                // the list's `ScrollView`, and nothing below sees it.
                if (stepListBars(p, tree, frames))
                {
                    if (p.action == PointerAction.release)
                        barCap = barCap.released(); // the central release
                    return;
                }
                if (!press)
                    return;
                // A press on a ranked row selects it and focuses the list;
                // rows carry their corpus index as `hitId + 1`.
                import sparkles.ui.state : hoverTargets;

                foreach (t; hoverTargets(tree, frames))
                {
                    if (t.hitId == 0 || !t.rect.contains(p.pos))
                        continue;
                    foreach (i; 0 .. state.rowCount)
                        if (state.rows[i].corpusIndex + 1 == t.hitId)
                        {
                            state.selection = i;
                            focus = ScopeFocus!Scope_(Scope_.pickerList);
                            return;
                        }
                }
                // Anywhere else on the files side is the prompt's.
                if (p.pos.x < geometry.panelCols)
                    focus = ScopeFocus!Scope_(Scope_.pickerInput);
            },
            (_) {},
        );
        return result;
    }

private:
    /**
    Derive each visible row's fuzzy-match byte ranges by re-running the
    positions tier against the same defaults the search admitted with — the
    shared typo-verification rule guarantees the two tiers agree on the set.
    */
    void refreshHighlights() @system
    {
        rowRangeCounts[] = 0;
        if (!state.active || state.rowCount == 0
            || state.prompt.length == 0)
            return;
        auto parsed = parseQuery(state.prompt.text);
        if (parsed.hasError)
            return;
        auto snap = finder.snapshot();
        foreach (i, ref const shownRow; state.visible)
        {
            const index = shownRow.corpusIndex;
            if (index >= snap.candidates.length)
                continue;
            TextRange[64] buffer = void;
            auto found = positions(parsed.value, snap.candidates[index],
                MatchConfig.init, FuzzyLimits.init, positionsWorkspace,
                buffer);
            if (found.hasError)
                continue; // an over-long range set simply shows unhighlighted
            const count = found.value < maxRowRanges
                ? found.value : maxRowRanges;
            foreach (k; 0 .. count)
                rowRanges[i][k] = buffer[k];
            rowRangeCounts[i] = count;
        }
    }

    void request() @system
    {
        // A prompt edit restarts the list at its top pick (`PIK10`). The
        // grep source made this visible in the worst way — its rows were
        // identified by INDEX, so the preserving lookup matched an unrelated
        // hit and the cursor landed mid-list — but the rule holds for every
        // source: the reader is asking a new question.
        state.restartSelection();
        final switch (source)
        {
        case PickerSource.files:
            auto requested = scheduler.request(state.prompt.text,
                finder.snapshot(), stepBudget);
            if (requested.hasError)
            {
                state.error = requested.error;
                state.searching = false;
            }
            return;
        case PickerSource.grep:
            grep.begin(state.prompt.text, searchPolicy);
            state.searching = grep.searching;
            state.corpusTotal = grep.corpusTotal;
            state.matchedTotal = 0;
            publishGrep();
            return;
        }
    }

    /**
    Drive the list's horizontal bar from a pointer event (`PKL8`).

    Geometry comes from `scrollLayout` over the SAME rect the bar was
    painted into, which is `SCV7`'s rule: one derivation, so paint and hit
    cannot drift. The `hitId` the view stamps on the node is what makes
    that rect findable rather than re-derived from magic offsets — the
    failure the scrollbar audit found at six other sites.
    */
    /// The rect a bar with `id` was PAINTED into, or an empty rect.
    private Rect barRect(size_t id, in WidgetTree tree,
        scope const(Frame)[] frames) @system
    {
        import sparkles.ui.state : hoverTargets;

        foreach (t; hoverTargets(tree, frames))
            if (t.hitId == id)
                return t.rect;
        return Rect.init;
    }

    /**
    Drive the list's VERTICAL bar (`PKL8`).

    The one input that moves the view without moving the cursor, so the
    selection is pulled along rather than left off screen.
    */
    private bool stepListVBar(in PointerEvent p, in WidgetTree tree,
        scope const(Frame)[] frames) @system
    {
        if (state.rowCount <= state.viewRows && !state.scroll.v.dragging)
            return false;
        const rect = barRect(pickerVBarHitId, tree, frames);
        if (rect.height == 0 && !state.scroll.v.dragging)
            return false;

        const lay = scrollLayout(ScrollArea(
            rect: rect,
            v: ScrollAreaAxis(content: cast(long) state.rowCount,
                viewport: cast(long) state.viewRows, gutter: 1),
            h: ScrollAreaAxis(content: 0, viewport: 0, gutter: 0)));
        const over = lay.vPointer(p).over;
        const wasGrab = state.scroll.v.dragging;
        barCap = state.scroll.stepV(barCap, listVBarCapId, p,
            cast(long) state.firstRow, lay);
        cast(void) state.scrollRowsTo(state.scroll.v.offset);
        return over || wasGrab || state.scroll.v.dragging;
    }

    /// Both list bars, vertical first — a press inside the vertical gutter
    /// is never also inside the horizontal one, and checking the taller
    /// target first keeps the corner cell predictable.
    private bool stepListBars(in PointerEvent p, in WidgetTree tree,
        scope const(Frame)[] frames) @system
    {
        if (stepListVBar(p, tree, frames))
            return true;
        return stepListBar(p, tree, frames);
    }

    private bool stepListBar(in PointerEvent p, in WidgetTree tree,
        scope const(Frame)[] frames) @system
    {
        if (!state.hOverflows && !state.scroll.h.dragging)
            return false;

        // The rect the bar was PAINTED into, found by the identity the view
        // stamped on it — not a rect derived here from panel arithmetic.
        // The first version of this computed its own `Rect(1, 1, …)` and was
        // inert against the real layout: the bar is a child of the panel's
        // body flow, so its row is wherever the rows above it ended, which
        // no arithmetic outside the layout can know. That is `SCV7`
        // precisely — one derivation, or paint and hit disagree — and its
        // test passed only because the test picked the same wrong rect.
        const hRect = barRect(pickerHBarHitId, tree, frames);
        if (hRect.width == 0 && !state.scroll.h.dragging)
            return false;

        const lay = scrollLayout(ScrollArea(
            rect: hRect,
            v: ScrollAreaAxis(content: 0, viewport: 0, gutter: 0),
            h: ScrollAreaAxis(content: cast(long) state.contentCols,
                viewport: cast(long) state.viewCols, gutter: 1)));
        const over = lay.hPointer(p).over;
        const wasGrab = state.scroll.h.dragging;
        barCap = state.scroll.stepH(barCap, listBarCapId, p,
            state.scroll.h.offset, lay);
        return over || wasGrab || state.scroll.h.dragging;
    }

public:
    /**
    Where the SELECTED row points, for the preview (`PKS2`).

    A files row names no position and no needle, so the preview opens as it
    always has. A grep row names both, and a preview that ignored them would
    show the reader the one part of the document they did not ask about.
    */
    PickerTarget selectedTarget() @system
    {
        final switch (source)
        {
        case PickerSource.files: return PickerTarget.init;
        case PickerSource.grep: return grep.resolve(state.selectedCorpusIndex);
        }
    }

    /// The needle the preview should light — the prompt, minus anything the
    /// query language consumed. Empty for the files source, whose matches
    /// are against the PATH and already drawn on the row.
    const(char)[] previewNeedle() @system
    {
        final switch (source)
        {
        case PickerSource.files: return null;
        case PickerSource.grep: return state.prompt.text;
        }
    }

private:
    /// Where the row at `index` goes, whichever source produced it.
    PickerTarget resolveRow(size_t index) @system
    {
        final switch (source)
        {
        case PickerSource.files: return finder.resolve(index);
        case PickerSource.grep: return grep.resolve(index);
        }
    }

    /// Publish the grep scan's current page into the shared state.
    private void publishGrep() @system
    {
        RankedResult[pickerTopK] page = void;
        const n = grep.page(page[]);
        state.publish(page[0 .. n], state.generation + 1, grep.searching);
        state.matchedTotal = grep.hitCount;
        state.corpusTotal = grep.corpusTotal;
    }

    /// Everything the view reads, folded into one comparable value so `poll`
    /// can report "changed" without the host diffing rows itself.
    ulong fingerprint() const @safe pure nothrow @nogc
    {
        ulong result = state.generation;
        result = result * 31 + state.rowCount;
        result = result * 31 + state.selection;
        result = result * 31 + (state.searching ? 1 : 0);
        result = result * 31 + state.error.code;
        foreach (ref row; state.rows)
            result = result * 31 + row.id.low;
        return result;
    }
}

version (unittest)
{
    import sparkles.input.events : Mods;

    private string pickerFixture(string stem) @system
    {
        import std.file : mkdirRecurse, tempDir, write;
        import std.path : buildPath;
        import std.uuid : randomUUID;

        const root = buildPath(tempDir(), stem ~ "-" ~ randomUUID.toString);
        mkdirRecurse(buildPath(root, "src"));
        write(buildPath(root, "src", "app.d"), "void main() {}\n");
        write(buildPath(root, "src", "lib.d"), "int x;\n");
        write(buildPath(root, "readme.md"), "hi\n");
        return root;
    }

    private void drain(ref PickerHost host) @system
    {
        import core.thread : Thread;

        foreach (_; 0 .. 100_000)
        {
            cast(void) host.poll();
            if (!host.busy)
                return;
            Thread.yield();
        }
    }
}

@("picker.host.openTypeAcceptRoundTrip")
@system
unittest
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    const root = pickerFixture("hue-picker-host");
    scope (exit) rmdirRecurse(root);

    auto owner = makeUnique!PickerHost();
    auto host = &owner.get();
    scope (exit) host.shutdown();
    host.open(root);
    assert(host.state.active);
    drain(*host);
    assert(host.state.error.code == 0);
    assert(host.state.rowCount == 3, "the empty prompt ranks the whole corpus");

    // Typing narrows per keystroke; `lib` keeps exactly one file.
    foreach (ch; "lib")
        assert(host.handleKey(KeyEvent(Key.char_, ch))
            == PickerAction.consumed);
    drain(*host);
    assert(host.state.rowCount == 1);

    assert(host.handleKey(KeyEvent(Key.enter)) == PickerAction.accepted);
    assert(host.acceptedPath == buildPath(root, "src/lib.d"));
    assert(!host.state.active);

    // Reopening re-walks and resets the prompt.
    host.open(root);
    drain(*host);
    assert(host.state.prompt.length == 0 && host.state.rowCount == 3);
    assert(host.handleKey(KeyEvent(Key.escape)) == PickerAction.closed);
    assert(!host.state.active);
}

@("picker.host.modalKeysSelectAndToggleDebug")
@system
unittest
{
    import std.file : rmdirRecurse;

    const root = pickerFixture("hue-picker-host-keys");
    scope (exit) rmdirRecurse(root);

    auto owner = makeUnique!PickerHost();
    auto host = &owner.get();
    scope (exit) host.shutdown();
    host.open(root);
    drain(*host);
    assert(host.state.rowCount == 3);

    assert(host.handleKey(KeyEvent(Key.down)) == PickerAction.consumed);
    assert(host.state.selection == 1);
    assert(host.handleKey(KeyEvent(Key.up)) == PickerAction.consumed);
    assert(host.state.selection == 0);

    assert(host.handleKey(KeyEvent(Key.char_, 's', Mods(ctrl: true)))
        == PickerAction.consumed);
    assert(host.state.showScoreDebug && host.state.debugScore.present);

    // A letter that matches nothing empties the rows; Enter then has nothing
    // to accept and must not close the picker.
    foreach (ch; "zzzz")
        cast(void) host.handleKey(KeyEvent(Key.char_, ch));
    drain(*host);
    assert(host.state.rowCount == 0);
    assert(host.handleKey(KeyEvent(Key.enter)) == PickerAction.consumed);
    assert(host.state.active);
}

@("picker.host.focusCyclesAndRoutesKeys")
@system
unittest
{
    import std.file : rmdirRecurse;

    const root = pickerFixture("hue-picker-host-focus");
    scope (exit) rmdirRecurse(root);

    auto owner = makeUnique!PickerHost();
    auto host = &owner.get();
    scope (exit) host.shutdown();
    host.open(root);
    drain(*host);
    assert(host.focus.isFocused(Scope_.pickerInput), "the prompt opens focused");

    // Tab cycles input → list → preview → input; Shift-Tab reverses.
    assert(host.handleKey(KeyEvent(Key.tab)) == PickerAction.consumed);
    assert(host.focus.isFocused(Scope_.pickerList));
    assert(host.handleKey(KeyEvent(Key.tab)) == PickerAction.consumed);
    assert(host.focus.isFocused(Scope_.pickerPreview));
    assert(host.handleKey(KeyEvent(Key.tab)) == PickerAction.consumed);
    assert(host.focus.isFocused(Scope_.pickerInput));
    import sparkles.input.events : Mods;

    assert(host.handleKey(KeyEvent(Key.tab, 0, Mods(shift: true)))
        == PickerAction.consumed);
    assert(host.focus.isFocused(Scope_.pickerPreview), "Shift-Tab reverses");

    // While the preview holds focus, an unbound key forwards to the pane…
    auto r = host.handleKey(KeyEvent(Key.char_, 'j'));
    assert(r == PickerAction.preview
        && host.previewEvent.match!((in KeyEvent fk) => fk.ch, _ => dchar(0))
            == 'j',
        "preview keys belong to the document pane");
    // …the shared picker keys still resolve…
    assert(host.handleKey(KeyEvent(Key.escape)) == PickerAction.closed);
    assert(!host.state.active);

    // Reopening resets the focus to the prompt.
    host.open(root);
    drain(*host);
    assert(host.focus.isFocused(Scope_.pickerInput));

    // The focused list navigates with letters, and a printable refocuses the
    // prompt and types instead of being swallowed.
    cast(void) host.handleKey(KeyEvent(Key.tab));
    assert(host.handleKey(KeyEvent(Key.char_, 'j')) == PickerAction.consumed);
    assert(host.state.selection == 1 && host.focus.isFocused(Scope_.pickerList));
    assert(host.handleKey(KeyEvent(Key.char_, 'G', Mods(shift: true)))
        == PickerAction.consumed);
    assert(host.state.selection + 1 == host.state.rowCount, "G hits the last row");
    assert(host.handleKey(KeyEvent(Key.char_, 'l')) == PickerAction.consumed);
    assert(host.focus.isFocused(Scope_.pickerInput),
        "a printable is a query edit, never list chrome");
    assert(host.state.prompt.text == "l");

    // Ctrl-D scrolls the preview from any pane — the translated page key.
    r = host.handleKey(KeyEvent(Key.char_, 'd', Mods(ctrl: true)));
    assert(r == PickerAction.preview
        && host.previewEvent.match!((in KeyEvent fk) => fk.key, _ => Key.none)
            == Key.pageDown);
}

@("picker.host.overlayRoutesWheelAndPointerByPosition")
@system
unittest
{
    import std.file : rmdirRecurse;
    import sparkles.ui.state : hoverTargets;

    const root = pickerFixture("hue-picker-host-overlay");
    scope (exit) rmdirRecurse(root);

    auto owner = makeUnique!PickerHost();
    auto host = &owner.get();
    scope (exit) host.shutdown();
    host.open(root);
    drain(*host);
    assert(host.state.rowCount == 3);

    // Derive the geometry the router derives — the same tree, the same
    // frames (`INP10`), so the test cannot disagree with the routing about
    // where anything is.
    const geometry = PickerGeometry(panelCols: 40, panelRows: 12);
    auto tree = host.buildView(geometry);
    auto frames = layout(tree, Constraints(maxW: 2 * geometry.panelCols));
    const hole = pickerPreviewRect(tree, frames);
    assert(hole.width > 0);

    // The wheel scrolls the element under the cursor (`DCK7` inside the
    // modal): over the list it moves the selection…
    assert(host.handleOverlay(Event(WheelEvent(dy: 1, pos: Point(3, 3))),
        geometry) == PickerAction.consumed);
    assert(host.state.selection == 1);

    // …over the preview hole it forwards, position made pane-local.
    assert(host.handleOverlay(Event(WheelEvent(dy: 2,
        pos: Point(hole.x + 2, hole.y + 1))), geometry)
        == PickerAction.preview);
    const fw = host.previewEvent.match!(
        (in WheelEvent w) => w, _ => WheelEvent.init);
    assert(fw.dy == 2 && fw.pos == Point(2, 1), "the position is pane-local");

    // A press on a ranked row selects it and focuses the list.
    Rect rowRect;
    foreach (t; hoverTargets(tree, frames))
        if (t.hitId == host.state.rows[0].corpusIndex + 1)
            rowRect = t.rect;
    assert(rowRect.width > 0, "the rows are hit-testable");
    assert(host.handleOverlay(Event(PointerEvent(
        pos: Point(rowRect.x + 1, rowRect.y),
        action: PointerAction.press, button: PointerButton.left)), geometry)
        == PickerAction.consumed);
    assert(host.state.selection == 0);
    assert(host.focus.isFocused(Scope_.pickerList), "a click focuses the list");

    // A press in the hole focuses the preview, forwards pane-local, and
    // grabs (`STM11`): drags forward wherever they stray until the release,
    // which is what keeps the document pane's scrollbar drags alive.
    assert(host.handleOverlay(Event(PointerEvent(
        pos: Point(hole.x + 1, hole.y + 2),
        action: PointerAction.press, button: PointerButton.left)), geometry)
        == PickerAction.preview);
    assert(host.focus.isFocused(Scope_.pickerPreview));
    assert(host.handleOverlay(Event(PointerEvent(pos: Point(0, 0),
        action: PointerAction.drag, button: PointerButton.left)), geometry)
        == PickerAction.preview, "a grab keeps every motion");
    assert(host.handleOverlay(Event(PointerEvent(pos: Point(0, 0),
        action: PointerAction.release, button: PointerButton.left)), geometry)
        == PickerAction.preview);
    assert(host.handleOverlay(Event(PointerEvent(pos: Point(0, 0),
        action: PointerAction.drag, button: PointerButton.left)), geometry)
        == PickerAction.consumed, "the release ended the grab");
}

@("picker.host.locationSuffixReachesTheAcceptedTarget")
@system
unittest
{
    // `PKQ4` — the whole point of parsing a trailing `:line[:col]`. The
    // query language had parsed it since the parser landed, and NOTHING
    // consumed it: pasting `src/app.d:120` from a compiler diagnostic
    // narrowed the list correctly and then opened at the top of the file,
    // which looks like the feature working right up until you look at where
    // the cursor is.
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    const root = pickerFixture("hue-picker-loc");
    scope (exit) rmdirRecurse(root);

    auto owner = makeUnique!PickerHost();
    auto host = &owner.get();
    scope (exit) host.shutdown();
    host.open(root);
    drain(*host);

    foreach (ch; "lib:12:5")
        host.handleKey(KeyEvent(Key.char_, ch));
    drain(*host);
    assert(host.state.rowCount == 1,
        "the location suffix must not be matched as part of the path");

    assert(host.handleKey(KeyEvent(Key.enter)) == PickerAction.accepted);
    assert(host.acceptedTarget.path == buildPath(root, "src/lib.d"));
    assert(host.acceptedTarget.line == 12, "the line suffix was dropped");
    assert(host.acceptedTarget.column == 5, "the column suffix was dropped");

    // A bare path still names no position, so the viewer keeps its scroll.
    auto owner2 = makeUnique!PickerHost();
    auto plain = &owner2.get();
    scope (exit) plain.shutdown();
    plain.open(root);
    drain(*plain);
    foreach (ch; "lib")
        plain.handleKey(KeyEvent(Key.char_, ch));
    drain(*plain);
    assert(plain.handleKey(KeyEvent(Key.enter)) == PickerAction.accepted);
    assert(plain.acceptedTarget.line == 0,
        "a query with no suffix must not invent a position");
}

@("picker.host.grepSourceOpensSearchesAndAcceptsALocation")
@system
unittest
{
    // The mount: the engine stops being dead code here. Everything below
    // goes through the host's real entry points — `openGrep`, typed keys,
    // `poll`, Enter — because the seam worth testing is the one the
    // workspace actually calls.
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "hue-grep-host-" ~ randomUUID.toString);
    mkdirRecurse(buildPath(root, "src"));
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, "src", "widget.d"), "struct Widget\n{\n}\n");
    write(buildPath(root, "src", "use.d"), "    Widget w;\n");

    auto owner = makeUnique!PickerHost();
    auto host = &owner.get();
    scope (exit) host.shutdown();

    host.openGrep(root);
    assert(host.source == PickerSource.grep);
    assert(host.state.active);

    foreach (ch; "Widget")
        assert(host.handleKey(KeyEvent(Key.char_, ch))
            == PickerAction.consumed);
    // Drive the scan to completion through the frame entry point.
    foreach (_; 0 .. 64)
        if (!host.busy)
            break;
        else
            cast(void) host.poll();

    assert(host.state.rowCount == 2, "one declaration, one mention");

    // `PKC13`: the declaration is first.
    const top = host.grep.rowText(host.state.rows[0].corpusIndex);
    assert(top.definition, "the declaration outranks the mention");
    assert(top.label == "src/widget.d");

    // `PKC3`: accepting names a LOCATION, and the host reports it.
    assert(host.handleKey(KeyEvent(Key.enter)) == PickerAction.accepted);
    assert(host.acceptedTarget.path == buildPath(root, "src/widget.d"));
    assert(host.acceptedTarget.line == 1);
    assert(host.acceptedTarget.column == 8, "`struct ` is 7 bytes");
    assert(host.acceptedTarget.handle.valid);

    // The files source still works from the same host — the two corpora
    // live side by side rather than one replacing the other.
    host.open(root);
    assert(host.source == PickerSource.files);
    drain(*host);
    assert(host.state.rowCount >= 2);
    assert(host.acceptedTarget.line == 1,
        "a files row leaves the previous target alone until one is accepted");
}

@("picker.host.theListBarTakesAMouseDrag")
@system
unittest
{
    // The bug this exists to prevent: the first version of the list's
    // horizontal bar was a hand-drawn string of glyphs with no `hitId` and
    // no `ScrollbarState`. It painted correctly and the arrow keys drove
    // it, so every test passed — and it was inert to the pointer, because
    // nothing routed events to a decoration. Keys are not a substitute for
    // a bar; a reader who reaches for the mouse finds nothing there.
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    const root = pickerFixture("hue-picker-bar");
    scope (exit) rmdirRecurse(root);
    const deep = buildPath(root, "docs", "research", "window-system", "os-apis");
    mkdirRecurse(deep);
    write(buildPath(deep, "distinctive.d"), "void f() { needleHere(); }\n");

    auto owner = makeUnique!PickerHost();
    auto host = &owner.get();
    scope (exit) host.shutdown();
    host.openGrep(root);
    foreach (ch; "needleHere")
        host.handleKey(KeyEvent(Key.char_, ch));
    foreach (_; 0 .. 64)
        if (!host.busy) break; else cast(void) host.poll();
    assert(host.state.rowCount == 1);

    // Find where the bar was actually PAINTED, by the identity the view
    // stamps on it. The first version of this test hardcoded a row derived
    // from the panel height — the same wrong arithmetic the code used — so
    // it passed against a bar that was nowhere near there. A test that
    // re-derives the geometry under test cannot catch the geometry being
    // wrong (`SCV7`).
    import sparkles.ui.state : hoverTargets;
    import picker_view : pickerHBarHitId;

    const geometry = PickerGeometry(panelCols: 30, panelRows: 12);
    auto tree = host.buildView(geometry);
    auto frames = layout(tree, Constraints(maxW: 2 * geometry.panelCols));
    assert(host.state.hOverflows, "the row is wider than the panel");
    assert(host.state.hOffset == 0);

    Rect bar;
    foreach (t; hoverTargets(tree, frames))
        if (t.hitId == pickerHBarHitId)
            bar = t.rect;
    assert(bar.width > 0, "the bar must be findable by its identity");

    // A press on the TRACK, right of the thumb, jumps toward it — the
    // machine's semantics, which a hand-rolled bar would have had to
    // reinvent (press-on-thumb grabs in place; press-on-track jumps).
    const barY = bar.y;
    assert(host.handleOverlay(Event(PointerEvent(
        pos: Point(bar.x + bar.width - 2, barY),
        action: PointerAction.press, button: PointerButton.left)), geometry)
        == PickerAction.consumed);
    const afterPress = host.state.hOffset;
    assert(afterPress > 0, "a press on the track scrolls the list");
    assert(host.state.scroll.h.dragging, "and begins a grab");

    // The grab OWNS the pointer: a drag that strays off the track keeps
    // scrolling rather than falling into the row-selection arm.
    cast(void) host.handleOverlay(Event(PointerEvent(
        pos: Point(bar.x, barY + 40),
        action: PointerAction.drag, button: PointerButton.left)), geometry);
    assert(host.state.hOffset < afterPress,
        "dragging back left scrolls back, even off the track");
    assert(host.state.selection == 0, "and never selected a row");

    // Release ends the grab.
    cast(void) host.handleOverlay(Event(PointerEvent(pos: Point(bar.x, barY),
        action: PointerAction.release, button: PointerButton.left)), geometry);
    assert(!host.state.scroll.h.dragging, "the grab ended");
}

@("picker.host.theListsVerticalBarTakesAMouseDrag")
@system
unittest
{
    // The vertical bar was emitted as a widget and never routed a pointer
    // event — the same omission as the horizontal one, one commit later.
    // It is the ONE input that moves the view without moving the cursor,
    // so it also has to pull the selection along: a picker whose
    // highlighted row is off screen has lost the reader's place, and Enter
    // would open something they cannot see.
    import sparkles.ui.state : hoverTargets;
    import std.conv : to;
    import std.file : rmdirRecurse, write;
    import std.path : buildPath;
    import picker_view : pickerVBarHitId;

    const root = pickerFixture("hue-picker-vbar");
    scope (exit) rmdirRecurse(root);
    foreach (i; 0 .. 40)
        write(buildPath(root, "zeta" ~ i.to!string ~ ".d"), "int x;\n");

    auto owner = makeUnique!PickerHost();
    auto host = &owner.get();
    scope (exit) host.shutdown();
    host.open(root);
    foreach (ch; "zeta")
        host.handleKey(KeyEvent(Key.char_, ch));
    drain(*host);

    const geometry = PickerGeometry(panelCols: 34, panelRows: 14);
    auto tree = host.buildView(geometry);
    auto frames = layout(tree, Constraints(maxW: 2 * geometry.panelCols));
    assert(host.state.rowCount > host.state.viewRows,
        "the ranking is deeper than the pane");

    Rect bar;
    foreach (t; hoverTargets(tree, frames))
        if (t.hitId == pickerVBarHitId)
            bar = t.rect;
    assert(bar.height > 0, "the vertical bar is findable by its identity");
    assert(host.state.firstRow == 0);

    // A press low on the track scrolls the view down.
    assert(host.handleOverlay(Event(PointerEvent(
        pos: Point(bar.x, bar.y + bar.height - 1),
        action: PointerAction.press, button: PointerButton.left)), geometry)
        == PickerAction.consumed);
    assert(host.state.firstRow > 0, "a press on the track scrolls the list");
    assert(host.state.scroll.v.dragging, "and begins a grab");

    // The selection came with it rather than being left off screen.
    assert(host.state.selection >= host.state.firstRow
        && host.state.selection < host.state.firstRow + host.state.viewRows,
        "the cursor stays inside the window the bar moved to");

    // The grab owns the pointer: a drag back up scrolls back, even off track.
    const low = host.state.firstRow;
    cast(void) host.handleOverlay(Event(PointerEvent(pos: Point(bar.x + 40, bar.y),
        action: PointerAction.drag, button: PointerButton.left)), geometry);
    assert(host.state.firstRow < low, "dragging up scrolls back");

    cast(void) host.handleOverlay(Event(PointerEvent(pos: Point(bar.x, bar.y),
        action: PointerAction.release, button: PointerButton.left)), geometry);
    assert(!host.state.scroll.v.dragging, "the grab ended");
}
