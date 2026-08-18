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

import sparkles.event_horizon.raw_pool : RawPoolResult;
import sparkles.fuzzy : CandidateSnapshot, DefaultFuzzyCaps, FuzzyLimits,
    MatchConfig, MatcherWorkspace, parseQuery, positions, TextRange;
import sparkles.input.events : Key, KeyEvent;
import sparkles.ui.widget : WidgetTree;

import picker : PickerScheduler, PickerState;
import picker_sources : collectFilesFinder, FilesFinder;
import picker_view : PickerGeometry, PickerLayout, pickerView, RowHighlight;

/// What a modal keystroke did — the host acts on `accepted` (open the file)
/// and repaints on the rest.
enum PickerAction : ubyte
{
    consumed, /// state changed (or the key was swallowed); still open
    closed,   /// the picker dismissed itself
    accepted, /// a row was accepted — `acceptedPath` names the file
}

/// Ranked rows the hosts show and select through. Deliberately small: the
/// terminal workspace has ~20 usable rows, and typing refines faster than
/// scrolling a long page (the `P1` layouts revisit this).
enum size_t pickerRows = 16;

/**
One host-owned picker: corpus, scheduler, state, and the modal key policy.

Non-copyable (the scheduler's generation slots are address-stable), so hosts
hold a `PickerHost*` allocated on first open — a user action, under hue's
startup/shutdown allocation carve-out (`NFR1`). `shutdown` must run before
the host exits; it stops the worker pool.
*/
struct PickerHost
{
    @disable this(this);

    PickerState!pickerRows state;
    PickerScheduler!(DefaultFuzzyCaps, pickerRows) scheduler;
    FilesFinder finder;
    /// Set by `handleKey` when it returns `PickerAction.accepted`.
    string acceptedPath;

    private alias Pool = typeof(scheduler).Pool;
    private Pool pool;
    private bool poolLive;
    private bool poolTried;

    // Render-time decor, refreshed when the rows change: fuzzy-match byte
    // ranges per visible row (the positions-on-demand doctrine — never
    // stored on results), and the resolved selected path the hosts feed
    // their preview document pane with.
    private MatcherWorkspace!DefaultFuzzyCaps positionsWorkspace;
    private TextRange[maxRowRanges][pickerRows] rowRanges;
    private size_t[pickerRows] rowRangeCounts;
    private size_t selectedIndex_ = size_t.max;
    private string selectedPath_;

    private enum size_t maxRowRanges = 8;

    /// One duration-bounded search step per request/poll (`PIK5`).
    private enum stepBudget = 4.msecs;

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
        state.open();
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
            selectedPath_ = finder.resolve(index);
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

        RowHighlight[pickerRows] highlights;
        foreach (i; 0 .. state.rowCount)
            highlights[i] = RowHighlight(rowRanges[i][0 .. rowRangeCounts[i]]);
        const path = selectedPath();
        return pickerView(state, snapshot,
            highlights[0 .. state.rowCount],
            path.length ? baseName(path) : null, geometry, preset);
    }

    /**
    The modal key policy, identical in both hosts: typing edits the prompt,
    `↑`/`↓` and `PgUp`/`PgDn` move the selection, `Enter` accepts, `Escape`
    closes, `Ctrl-S` toggles the score breakdown (`PKR4`'s debug view).
    Every key is consumed while the picker is open — it is a modal surface.
    */
    PickerAction handleKey(in KeyEvent k) @system
    {
        if (k.key == Key.escape || k.key == Key.back)
        {
            close();
            return PickerAction.closed;
        }
        if (k.key == Key.enter)
        {
            const index = state.selectedCorpusIndex;
            const path = finder.resolve(index);
            if (path is null)
                return PickerAction.consumed; // nothing to accept yet
            acceptedPath = path;
            close();
            return PickerAction.accepted;
        }
        if (k.key == Key.backspace)
        {
            if (state.prompt.erase())
                request();
            return PickerAction.consumed;
        }
        if (k.key == Key.up)
        {
            state.moveSelection(-1);
            return PickerAction.consumed;
        }
        if (k.key == Key.down)
        {
            state.moveSelection(1);
            return PickerAction.consumed;
        }
        if (k.key == Key.pageUp)
        {
            state.moveSelection(-cast(long) pickerRows / 2);
            return PickerAction.consumed;
        }
        if (k.key == Key.pageDown)
        {
            state.moveSelection(pickerRows / 2);
            return PickerAction.consumed;
        }
        if (k.key == Key.char_ && k.mods.ctrl)
        {
            if (k.ch == 's' || k.ch == 'S')
                state.toggleScoreDebug();
            return PickerAction.consumed;
        }
        if (k.key == Key.char_ && !k.mods.alt && k.ch >= 0x20)
        {
            if (state.prompt.type(k.ch))
                request();
            return PickerAction.consumed;
        }
        return PickerAction.consumed;
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
        foreach (i; 0 .. state.rowCount)
        {
            const index = state.rows[i].corpusIndex;
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

    auto host = new PickerHost;
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

    auto host = new PickerHost;
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
