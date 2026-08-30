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
    Location, MatchConfig, MatcherWorkspace, parseQuery, positions, TextRange;
import sparkles.input.events : Event, Key, KeyEvent, match, PointerAction,
    PointerButton, PointerEvent, WheelEvent;
import sparkles.ui.focus : ScopeFocus;
import sparkles.ui.geometry : Constraints, Point, Rect;
import sparkles.ui.layout : layout;
import sparkles.ui.widget : WidgetTree;

import keymap : Command, commandFor, KeyContext, Scope_;
import picker : PickerScheduler, PickerState;
import picker_sources : collectFilesFinder, FilesFinder, PickerTarget;
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

/// Rows the list PAINTS at once. Bounded by the terminal workspace's ~20
/// usable rows (the `P1` layouts revisit this).
enum size_t pickerVisibleRows = 16;

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
        => finder.snapshot();

    /// Whether the loop must keep ticking to make progress (a running or
    /// pending generation) rather than blocking on input.
    bool busy() const @safe nothrow @nogc
        => state.active && (state.searching || scheduler.hasInFlight);

    /**
    Dispatch completions and publish the newest partial page. Call once per
    frame/pass; returns whether anything the host renders changed.
    */
    bool poll() @system
    {
        if (!state.active && !scheduler.hasInFlight)
            return false;
        const before = fingerprint();
        scheduler.poll(state);
        const changed = fingerprint() != before;
        if (changed)
            refreshHighlights();
        return changed;
    }

    /// The selected row's resolved absolute path (null when nothing is
    /// selected) — what the hosts feed their preview document pane.
    string selectedPath() @system
    {
        const index = state.selectedCorpusIndex;
        if (index != selectedIndex_)
        {
            selectedIndex_ = index;
            selectedPath_ = finder.resolve(index).path;
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
        return pickerView(state, snapshot,
            highlights[0 .. shown],
            path.length ? baseName(path) : null, geometry, preset,
            focus.focused);
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
        => KeyContext(pickerActive: true, pickerFocus: focus.focused);

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
            auto target = finder.resolve(index);
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
        auto requested = scheduler.request(state.prompt.text,
            finder.snapshot(), stepBudget);
        if (requested.hasError)
        {
            state.error = requested.error;
            state.searching = false;
        }
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
