/** Presentation-free picker state and generation-safe bounded scheduler. */
module picker;

import core.atomic : MemoryOrder, atomicLoad, atomicStore;
import core.time : Duration, MonoTime;

import sparkles.base.unique : makeUnique, Unique;
// The module, never the package: `sparkles.event_horizon`'s package module
// publicly imports the Linux fs/pty surface, and Android — Linux without
// those — cannot compile it, so a package import here breaks the APK build.
import sparkles.event_horizon.raw_pool : RawCompletion, RawCpuPool, RawJob,
    RawPoolResult;
import sparkles.fuzzy : CandidateId, CandidateSnapshot, CandidateView,
    ConstraintWorkspace,
    DefaultFuzzyCaps, FuzzyError, FuzzyErrorCode, FuzzyExpected, FuzzyLimits,
    MatchConfig, MatcherWorkspace, QueryParseOptions, QueryStorage,
    RankedResult, Scoring, SearchAccumulator, SearchCursor, SearchLimits,
    SearchStop, fuzzyErr, fuzzyOk, parseQuery, searchChunk;
import sparkles.ui.components.scroll_view : ScrollView;

/// Fixed UTF-8 prompt editor; accepted keystrokes never allocate.
struct PickerPrompt(size_t Capacity = 256)
if (Capacity > 0)
{
    private char[Capacity] bytes = void;
    private size_t length_;
    bool active;

    const(char)[] text() const return scope @trusted pure nothrow @nogc
        => bytes[0 .. length_];
    size_t length() const @safe pure nothrow @nogc => length_;

    void start() @safe pure nothrow @nogc
    {
        length_ = 0;
        active = true;
    }

    bool type(dchar value) @safe pure nothrow @nogc
    {
        import sparkles.base.text.utf : encodeScalar;

        if (value < 0x20 || value == 0x7F)
            return false;
        char[4] encoded = void;
        const count = encodeScalar(value, encoded[]).written;
        if (count == 0 || count > Capacity - length_)
            return false;
        foreach (i; 0 .. count)
            bytes[length_++] = encoded[i];
        return true;
    }

    bool erase() @safe pure nothrow @nogc
    {
        if (length_ == 0)
            return false;
        import sparkles.base.text.utf : decodeToken, UtfMode, UtfStatus;

        // type() is the sole writer: this buffer always contains valid scalars.
        size_t at, last;
        while (at < length_)
        {
            last = at;
            const decoded = decodeToken(bytes[at .. length_], UtfMode.strict, true, at);
            assert(decoded.result.status == UtfStatus.ok);
            at += decoded.result.consumed;
        }
        length_ = last;
        return true;
    }

    void accept() @safe pure nothrow @nogc
    {
        active = false;
    }
    void cancel() @safe pure nothrow @nogc
    {
        length_ = 0;
        active = false;
    }
}

/// Selected row's inspectable score terms for a backend debug panel.
struct PickerDebugScore
{
    bool present;
    RankedResult result;
}

/** Prompt, globally ranked rows, selection, and scroll — no canvas state. */
struct PickerState(size_t Capacity = 64, size_t PromptCapacity = 256)
if (Capacity > 0 && PromptCapacity > 0)
{
    PickerPrompt!PromptCapacity prompt;
    private RankedResult[Capacity] rows_ = void;
    private size_t rowCount_;
    size_t selection;
    ulong generation;
    /// Candidates admitted so far this generation (grows while `searching`).
    size_t matchedTotal;
    /// The corpus size the generation searched — the `332/2350` denominator.
    size_t corpusTotal;
    bool active;
    bool searching;
    bool showScoreDebug;
    FuzzyError error;

    /**
    How many rows the list paints at once.

    Separate from `Capacity`, which is how many ranked results are KEPT.
    They were the same number while every source was a file picker, where a
    handful of top hits answer the question. A grep query does not work that
    way — the interesting hit is routinely the twentieth — so the ranking is
    kept deeper than the viewport and the list scrolls through it, rather
    than the ranking being truncated to what happens to fit.
    */
    size_t viewRows = 16;
    private size_t firstRow_;

    /**
    The list's scroll machines (`PKL8`, `SCV1`).

    A `ScrollView`, not a bare offset: the first version of this carried a
    `size_t` and painted a decorative string, which made it the SEVENTH site
    to assemble a scrollbar by convention in a codebase that had just
    finished collapsing six into one component. The machine owns the parts
    that are easy to get wrong on the eighth try — press-on-thumb grabs in
    place while press-on-track jumps, the grab owns the pointer until
    release, hover is a state, and the offset clamps in exactly one place.

    Only the horizontal axis is driven today; the list's vertical movement
    is a SELECTION (`firstRow_` follows it), not a scroll offset.
    */
    ScrollView scroll;

    /// The list's horizontal offset, in cells — the machine's, surfaced
    /// under the name the view reads.
    size_t hOffset() const @safe pure nothrow @nogc
        => scroll.h.offset < 0 ? 0 : cast(size_t) scroll.h.offset;
    /// The widest painted row, in cells — the extent the bar describes.
    /// Published by the view, which is the only thing that knows how wide a
    /// row rendered.
    size_t contentCols;
    /// Cells the list can show at once, set by the host from the geometry.
    size_t viewCols = 40;

    /// Whether any painted row is wider than the panel.
    bool hOverflows() const @safe pure nothrow @nogc
        => contentCols > viewCols;

    /**
    Scroll the list vertically to put `first` at the top (`PKL8`).

    Used by the vertical bar, which is the one input that moves the VIEW
    without moving the cursor. The selection is then pulled into the visible
    window rather than left behind it: a picker whose highlighted row is off
    screen has lost the reader's place, and Enter would open something they
    cannot see.
    */
    bool scrollRowsTo(long first) @safe pure nothrow @nogc
    {
        if (rowCount_ == 0)
            return false;
        const win = viewRows == 0 ? 1 : viewRows;
        const maxFirst = rowCount_ > win ? rowCount_ - win : 0;
        auto next = first < 0 ? 0 : first;
        if (next > cast(long) maxFirst)
            next = cast(long) maxFirst;
        if (cast(size_t) next == firstRow_)
            return false;
        firstRow_ = cast(size_t) next;
        if (selection < firstRow_)
            selection = firstRow_;
        else if (selection >= firstRow_ + win)
            selection = firstRow_ + win - 1;
        return true;
    }

    /**
    A new query: the list starts at the top (`PIK10`).

    Editing the prompt makes a different ranking, and the row that was
    selected is not the row the reader is now asking about — the first hit
    is. Preserving the selection across an edit is right only while the
    QUERY is unchanged (a partial page growing under the cursor), which is
    why this is the prompt's business rather than `publish`'s.
    */
    void restartSelection() @safe pure nothrow @nogc
    {
        selection = 0;
        firstRow_ = 0;
        scroll.h = scroll.h.scrolledTo(0);
    }

    /**
    Scroll the list sideways, clamped to the widest row.

    Returns `false` when there is nothing to scroll, so a host can leave the
    key unhandled rather than repaint for nothing — the same contract
    `ViewerModel.scrollHorizontal` has.
    */
    bool scrollHorizontal(long delta) @safe pure nothrow @nogc
    {
        if (delta == 0 || !hOverflows)
            return false;
        const next = ScrollView.clampOffset(scroll.h.offset + delta,
            contentCols, viewCols);
        if (next == scroll.h.offset)
            return false;
        scroll.h = scroll.h.scrolledTo(next);
        return true;
    }

    /// The whole kept ranking, deeper than the viewport.
    const(RankedResult)[] rows() const return scope @trusted pure nothrow @nogc
        => rows_[0 .. rowCount_];
    size_t rowCount() const @safe pure nothrow @nogc => rowCount_;

    /// Index of the first painted row — the list's scroll offset.
    size_t firstRow() const @safe pure nothrow @nogc => firstRow_;

    /// The painted window: what the view iterates. Its indices are
    /// window-relative, so a caller adds `firstRow` to compare against
    /// `selection`.
    const(RankedResult)[] visible() const return scope @trusted pure nothrow @nogc
    {
        const win = viewRows == 0 ? 1 : viewRows;
        const stop = firstRow_ + win < rowCount_ ? firstRow_ + win : rowCount_;
        return firstRow_ < stop ? rows_[firstRow_ .. stop] : null;
    }

    /// Keep the selection inside the painted window, and the window inside
    /// the ranking. Called wherever either can move.
    private void clampScroll() @safe pure nothrow @nogc
    {
        if (rowCount_ == 0)
        {
            firstRow_ = 0;
            return;
        }
        const win = viewRows == 0 ? 1 : viewRows;
        if (selection < firstRow_)
            firstRow_ = selection;
        else if (selection >= firstRow_ + win)
            firstRow_ = selection - win + 1;
        const maxFirst = rowCount_ > win ? rowCount_ - win : 0;
        if (firstRow_ > maxFirst)
            firstRow_ = maxFirst;
    }

    void open() @safe pure nothrow @nogc
    {
        prompt.start();
        rowCount_ = 0;
        selection = 0;
        firstRow_ = 0;
        scroll = ScrollView.init;
        contentCols = 0;
        matchedTotal = 0;
        corpusTotal = 0;
        error = FuzzyError.init;
        active = true;
        searching = false;
    }

    void close() @safe pure nothrow @nogc
    {
        prompt.accept();
        active = false;
        searching = false;
    }

    void moveSelection(long delta) @safe pure nothrow @nogc
    {
        if (rowCount_ == 0)
        {
            selection = 0;
            return;
        }
        const wanted = cast(long) selection + delta;
        selection = wanted < 0 ? 0
            : wanted >= cast(long) rowCount_ ? rowCount_ - 1
            : cast(size_t) wanted;
        clampScroll();
    }

    void toggleScoreDebug() @safe pure nothrow @nogc
    {
        showScoreDebug = !showScoreDebug;
    }

    PickerDebugScore debugScore() const @safe pure nothrow @nogc
    {
        PickerDebugScore result;
        if (showScoreDebug && selection < rowCount_)
        {
            result.present = true;
            result.result = rows_[selection];
        }
        return result;
    }

    size_t selectedCorpusIndex() const @safe pure nothrow @nogc
        => selection < rowCount_ ? rows_[selection].corpusIndex : size_t.max;

public:
    void publish(scope const(RankedResult)[] values, ulong newGeneration,
        bool stillSearching) @safe pure nothrow @nogc
    {
        CandidateId selected;
        bool preserve = selection < rowCount_;
        if (preserve)
            selected = rows_[selection].id;
        rowCount_ = values.length < Capacity ? values.length : Capacity;
        foreach (i; 0 .. rowCount_)
            rows_[i] = values[i];
        // A new generation is a different set of rows, so a sideways offset
        // carried over from the last query would point into text that is no
        // longer there. Compared BEFORE the assignment, or the test is
        // trivially false and the offset never resets.
        if (generation != newGeneration)
            scroll.h = scroll.h.scrolledTo(0);
        generation = newGeneration;
        searching = stillSearching;
        error = FuzzyError.init;
        if (rowCount_ == 0)
            selection = 0;
        else if (preserve)
        {
            selection = 0;
            foreach (i; 0 .. rowCount_)
                if (rows_[i].id == selected)
                {
                    selection = i;
                    break;
                }
        }
        else if (selection >= rowCount_)
            selection = rowCount_ - 1;
        clampScroll();
    }
}

private enum GenerationState : ubyte
{
    idle,
    running,
}

private struct GenerationSlot(Caps, size_t ResultCapacity)
{
    char[Caps.maxQueryBytes] prompt = void;
    size_t promptLength;
    QueryStorage!Caps query;
    CandidateSnapshot snapshot;
    SearchAccumulator!ResultCapacity accumulator;
    SearchCursor cursor;
    MatcherWorkspace!Caps* matcher;
    size_t matcherLease = size_t.max;
    ConstraintWorkspace!Caps constraints;
    FuzzyLimits fuzzyLimits;
    MatchConfig matchConfig;
    Scoring scoring;
    Duration budget;
    ulong generation;
    size_t admittedTotal;
    shared(ulong)* publishedGeneration;
    FuzzyError error;
    bool finished;
    bool cancelled;
    bool ready;
    GenerationState state;
}

private struct MatcherArena(Caps)
{
    Unique!(MatcherWorkspace!Caps) workspace;
    bool leased;
}

/**
Closure-free picker scheduler over `RawCpuPool` with synchronous degradation.

Query bytes and result sinks live inside address-stable generation slots. New
requests publish their generation with release ordering and never overwrite a
running slot; workers acquire-load before each candidate-sized chunk. At open,
the scheduler allocates at most `workers + 1` pointer-free matcher arenas, capped
by `SlotCount`; the extra arena permits synchronous fallback alongside workers.
A slot leases an arena before parsing and keeps it until its completion retires,
including queued and cancelled jobs. Only the UI thread changes leases.
Constraint checks lend the same Unicode arena before matching; queries borrow
only pinned slot prompts and own their compiled globs. When no slot or arena is
free, the latest prompt is coalesced in a separate fixed buffer.
*/
struct PickerScheduler(Caps = DefaultFuzzyCaps, size_t ResultCapacity = 64,
    size_t SlotCount = 4, size_t QueueCapacity = 32,
    size_t CompletionCapacity = QueueCapacity)
if (ResultCapacity > 0 && SlotCount > 1)
{
    @disable this(this);

    alias Pool = RawCpuPool!(QueueCapacity, CompletionCapacity);
    private GenerationSlot!(Caps, ResultCapacity)[SlotCount] slots;
    private MatcherArena!Caps[SlotCount] arenas;
    private size_t arenaCount;
    private Pool* pool;
    private shared ulong publishedGeneration;
    private char[Caps.maxQueryBytes] pendingPrompt = void;
    private size_t pendingLength;
    private CandidateSnapshot pendingSnapshot;
    private Duration pendingBudget;
    private bool pending;
    private FuzzyLimits fuzzyLimits = FuzzyLimits.init;
    private MatchConfig matchConfig = MatchConfig.init;
    private Scoring scoring = Scoring.init;

    /// Allocate scratch for execution capacity at open, never on a prompt edit.
    void initialize() @safe pure nothrow @nogc
    {
        const workers = pool is null ? 0 : pool.workerCount;
        const required = workers < SlotCount ? workers + 1 : SlotCount;
        while (arenaCount < required)
        {
            arenas[arenaCount].workspace = makeUnique!(MatcherWorkspace!Caps)();
            assert(!arenas[arenaCount].workspace.empty, "PickerScheduler: workspace allocation failed");
            ++arenaCount;
        }
    }

    /// Attach at open, then initialize execution-capacity scratch before edits.
    void attach(ref Pool value) @safe nothrow @nogc
    {
        assert(pool is null || pool is &value || !hasInFlight,
            "PickerScheduler: retire jobs before replacing their pool");
        pool = &value;
    }

    /** Publish a new immutable prompt/corpus generation. */
    FuzzyExpected!ulong request(scope const(char)[] prompt,
        in CandidateSnapshot snapshot, Duration budget)
        @trusted nothrow @nogc
    {
        if (prompt.length > Caps.maxQueryBytes)
            return fuzzyErr!ulong(FuzzyErrorCode.queryTooComplex,
                prompt.length);
        if (budget <= Duration.zero)
            return fuzzyErr!ulong(FuzzyErrorCode.invalidConfiguration);
        auto generation = atomicLoad!(MemoryOrder.acq)(publishedGeneration);
        if (generation == ulong.max)
            return fuzzyErr!ulong(FuzzyErrorCode.arithmeticOverflow);
        foreach (i; 0 .. prompt.length)
            pendingPrompt[i] = prompt[i];
        pendingLength = prompt.length;
        pendingSnapshot = snapshot;
        pendingBudget = budget;
        ++generation;
        atomicStore!(MemoryOrder.rel)(publishedGeneration, generation);
        pending = true;
        launchPending(generation);
        return fuzzyOk(generation);
    }

    /**
    Dispatch completions, publish the newest global partial page, and schedule
    its next duration-bounded step. Call once per UI frame.
    */
    void poll(ref PickerState!ResultCapacity state) @trusted nothrow @nogc
    {
        if (pool !is null)
        {
            RawCompletion completion;
            while (pool.pollCompletion(completion) == RawPoolResult.accepted)
                completion.dispatch();
        }

        const newest = atomicLoad!(MemoryOrder.acq)(publishedGeneration);
        foreach (ref slot; slots)
        {
            if (slot.state != GenerationState.running || !slot.ready)
                continue;
            slot.ready = false;
            if (slot.generation != newest || slot.cancelled)
            {
                retire(slot);
                continue;
            }
            if (slot.error.code != FuzzyErrorCode.none)
            {
                state.error = slot.error;
                state.searching = false;
                state.generation = slot.generation;
                retire(slot);
                continue;
            }

            RankedResult[ResultCapacity] page = void;
            auto pageResult = slot.accumulator.page(page);
            if (pageResult.hasError)
            {
                state.error = pageResult.error;
                state.searching = false;
                retire(slot);
                continue;
            }
            state.publish(page[0 .. pageResult.value], slot.generation,
                !slot.finished);
            state.matchedTotal = slot.admittedTotal;
            state.corpusTotal = slot.snapshot.candidates.length;
            if (slot.finished)
                retire(slot);
            else
                submit(slot);
        }
        if (pending)
            launchPending(newest);
    }

    /// Release-publish cancellation. Slots retire only after completion.
    void cancel() @safe nothrow @nogc
    {
        auto generation = atomicLoad!(MemoryOrder.acq)(publishedGeneration);
        atomicStore!(MemoryOrder.rel)(publishedGeneration,
            generation == ulong.max ? 0 : generation + 1);
        pending = false;
    }

    bool hasInFlight() const @safe nothrow @nogc
    {
        foreach (ref const slot; slots)
            if (slot.state == GenerationState.running)
                return true;
        return false;
    }

private:
    bool lease(ref GenerationSlot!(Caps, ResultCapacity) slot)
        @trusted pure nothrow @nogc
    {
        foreach (i; 0 .. arenaCount)
        {
            ref arena = arenas[i];
            if (arena.leased)
                continue;
            arena.leased = true;
            slot.matcher = arena.workspace.ptr;
            slot.matcherLease = i;
            return true;
        }
        return false;
    }

    void retire(ref GenerationSlot!(Caps, ResultCapacity) slot)
        @safe pure nothrow @nogc
    {
        assert(slot.state == GenerationState.running);
        assert(slot.matcherLease < arenaCount);
        arenas[slot.matcherLease].leased = false;
        slot.matcher = null;
        slot.matcherLease = size_t.max;
        slot.state = GenerationState.idle;
    }

    void launchPending(ulong generation) @trusted nothrow @nogc
    {
        if (!pending)
            return;
        assert(arenaCount != 0, "PickerScheduler: initialize before requesting");
        foreach (ref slot; slots)
        {
            if (slot.state != GenerationState.idle)
                continue;
            if (!lease(slot))
                return;
            slot.promptLength = pendingLength;
            foreach (i; 0 .. pendingLength)
                slot.prompt[i] = pendingPrompt[i];
            slot.snapshot = pendingSnapshot;
            slot.budget = pendingBudget;
            slot.generation = generation;
            slot.publishedGeneration = &publishedGeneration;
            slot.fuzzyLimits = fuzzyLimits;
            slot.matchConfig = matchConfig;
            slot.scoring = scoring;
            slot.admittedTotal = 0;
            slot.error = FuzzyError.init;
            slot.finished = false;
            slot.cancelled = false;
            slot.ready = false;
            slot.state = GenerationState.running;

            QueryParseOptions options;
            options.limits = fuzzyLimits;
            auto parsed = parseQuery!Caps(slot.prompt[0 .. slot.promptLength],
                slot.matcher.textWorkspace, options);
            if (parsed.hasError)
            {
                slot.error = parsed.error;
                slot.finished = true;
                slot.ready = true;
                pending = false;
                return;
            }
            slot.query = parsed.value;
            auto begun = slot.accumulator.begin(slot.snapshot.id,
                slot.generation, slot.generation, 0, ResultCapacity);
            if (begun.hasError)
            {
                slot.error = begun.error;
                slot.finished = true;
                slot.ready = true;
                pending = false;
                return;
            }
            slot.cursor = begun.value;
            pending = false;
            submit(slot);
            return;
        }
    }

    void submit(ref GenerationSlot!(Caps, ResultCapacity) slot)
        @trusted nothrow @nogc
    {
        slot.ready = false;
        if (pool !is null)
        {
            auto submitted = pool.submit(RawJob(
                &runGeneration!(Caps, ResultCapacity),
                &completeGeneration!(Caps, ResultCapacity),
                &slot, slot.generation));
            if (submitted == RawPoolResult.accepted)
                return;
        }
        // Startup failure and either queue's saturation take the identical
        // bounded step on the calling thread (`PIK8`).
        runGeneration!(Caps, ResultCapacity)(&slot);
        slot.ready = true;
    }
}

private void runGeneration(Caps, size_t ResultCapacity)(void* raw)
    @trusted nothrow @nogc
{
    auto slot = cast(GenerationSlot!(Caps, ResultCapacity)*) raw;
    const deadline = MonoTime.currTime + slot.budget;
    do
    {
        if (atomicLoad!(MemoryOrder.acq)(*slot.publishedGeneration)
            != slot.generation)
        {
            slot.cancelled = true;
            slot.finished = true;
            return;
        }
        SearchLimits limits;
        limits.maxCandidates = 1;
        limits.maxAnalyzedUnits = slot.fuzzyLimits.maxCandidateUnits;
        auto status = searchChunk(slot.query, slot.snapshot, slot.cursor,
            limits, slot.matchConfig, slot.scoring, slot.fuzzyLimits,
            slot.accumulator, *slot.matcher, slot.constraints);
        if (status.hasError)
        {
            slot.error = status.error;
            slot.finished = true;
            return;
        }
        slot.cursor = status.value.cursor;
        slot.admittedTotal += status.value.admitted;
        if (status.value.stop == SearchStop.exhausted)
        {
            slot.finished = true;
            return;
        }
    }
    while (MonoTime.currTime < deadline);
}

private void completeGeneration(Caps, size_t ResultCapacity)(void* raw,
    bool cancelled) @trusted nothrow @nogc
{
    auto slot = cast(GenerationSlot!(Caps, ResultCapacity)*) raw;
    slot.cancelled |= cancelled;
    slot.ready = true;
}


@("picker.state.fixedPromptSelectionAndDebug")
@safe pure nothrow @nogc
unittest
{
    PickerState!4 state;
    state.open();
    assert(state.prompt.type('a') && state.prompt.type('é'));
    assert(state.prompt.text == "aé");
    assert(state.prompt.erase() && state.prompt.text == "a");
    RankedResult[2] rows;
    rows[0].id.low = 1;
    rows[0].score.total = 10;
    rows[1].id.low = 2;
    rows[1].score.total = 9;
    state.publish(rows[], 1, false);
    state.moveSelection(1);
    assert(state.selectedCorpusIndex == rows[1].corpusIndex);
    state.toggleScoreDebug();
    assert(state.debugScore.present
        && state.debugScore.result.score.total == 9);
}

@("picker.prompt.scalarEraseAndAtomicCapacity")
@safe pure nothrow @nogc unittest
{
    PickerPrompt!8 prompt;
    prompt.start();
    assert(prompt.type('e') && prompt.type('\u0301') && prompt.type('😀'));
    assert(prompt.text == "e\u0301😀");
    assert(!prompt.type('é') && prompt.text == "e\u0301😀");
    assert(prompt.erase() && prompt.text == "e\u0301");
    assert(prompt.erase() && prompt.text == "e");
    assert(!prompt.type(cast(dchar) 0xD800) && prompt.text == "e");
    assert(prompt.erase() && prompt.text == "");
    assert(!prompt.erase());
}

@("picker.scheduler.syncFallbackAndStaleRejection")
@system
unittest
{
    import core.time : msecs;

    CandidateView[4] candidates;
    static immutable names = ["src/app.d", "docs/readme.md",
        "src/lib.d", "other.txt"];
    foreach (i; 0 .. candidates.length)
    {
        candidates[i].id.low = i + 1;
        candidates[i].path = names[i];
        candidates[i].filenameOffset = names[i][0 .. 4] == "src/" ? 4 : 0;
    }
    CandidateSnapshot snapshot;
    snapshot.id.low = 9;
    snapshot.candidates = candidates[];

    // Heap-own address-stable slot metadata; its large pointer-free matcher
    // arenas are separately owned and not registered as collector ranges.
    auto owner = makeUnique!(PickerScheduler!(DefaultFuzzyCaps, 4))();
    auto scheduler = &owner.get();
    scheduler.initialize();
    auto oldGeneration = scheduler.request("docs", snapshot, 1.msecs);
    auto newest = scheduler.request("src/", snapshot, 1.msecs);
    assert(oldGeneration.hasValue && newest.hasValue
        && newest.value > oldGeneration.value);
    PickerState!4 state;
    state.open();
    foreach (_; 0 .. 16)
    {
        scheduler.poll(state);
        if (!state.searching && state.generation == newest.value)
            break;
    }
    assert(state.error.code == FuzzyErrorCode.none);
    assert(state.generation == newest.value);
    assert(state.rowCount == 2);
    foreach (row; state.rows)
        assert(candidates[row.corpusIndex].path[0 .. 4] == "src/");
}

@("picker.scheduler.rawPoolCompletionPublishes")
@system
unittest
{
    import core.thread : Thread;
    import core.time : msecs;

    CandidateView[3] candidates;
    static immutable names = ["alpha.d", "beta.d", "alphabet.md"];
    foreach (i; 0 .. candidates.length)
    {
        candidates[i].id.low = i + 1;
        candidates[i].path = names[i];
    }
    CandidateSnapshot snapshot;
    snapshot.id.low = 10;
    snapshot.candidates = candidates[];

    RawCpuPool!(32, 32) pool;
    assert(RawCpuPool!(32, 32).start(pool, 1)
        == RawPoolResult.accepted);
    scope (exit) cast(void) pool.shutdown(true);

    // Off the collected heap, as above.
    auto owner = makeUnique!(PickerScheduler!(DefaultFuzzyCaps, 4))();
    auto scheduler = &owner.get();
    scheduler.attach(pool);
    scheduler.initialize();
    auto generation = scheduler.request("alpha", snapshot, 1.msecs);
    assert(generation.hasValue);
    PickerState!4 state;
    state.open();
    foreach (_; 0 .. 100_000)
    {
        scheduler.poll(state);
        if (state.generation == generation.value && !state.searching)
            break;
        Thread.yield();
    }
    assert(state.error.code == FuzzyErrorCode.none);
    assert(state.generation == generation.value);
    assert(state.rowCount == 2);
    assert(!scheduler.hasInFlight);
}

@("picker.scheduler.concurrentGenerationsRetainQueriesUntilCompletion")
@system unittest
{
    import core.atomic : atomicOp;
    import core.thread : Thread;
    import core.time : msecs, seconds;

    static struct Gate
    {
        shared uint entered;
        shared bool release;
    }
    static void block(void* raw) @trusted nothrow @nogc
    {
        auto gate = cast(Gate*) raw;
        atomicOp!"+="(gate.entered, 1);
        while (!atomicLoad(gate.release))
            Thread.yield();
    }

    CandidateView[3] candidates;
    static immutable paths = ["src/café.d", "docs/café.md", "src/zebra.d"];
    foreach (i; 0 .. candidates.length)
    {
        candidates[i].id.low = i + 1;
        candidates[i].path = paths[i];
        candidates[i].filenameOffset = i == 1 ? 5 : 4;
    }
    CandidateSnapshot snapshot;
    snapshot.id.low = 11;
    snapshot.candidates = candidates[];
    static immutable queries = ["alpha glob:src/*.d",
        "beta glob:docs/*.md", "gamma glob:other/*.txt"];

    foreach (uint workers; 1 .. 3)
    {
        alias Scheduler = PickerScheduler!(DefaultFuzzyCaps, 4, 4, 8, 8);
        Scheduler.Pool pool;
        Gate gate;
        auto owner = makeUnique!Scheduler();
        auto scheduler = &owner.get();
        assert(Scheduler.Pool.start(pool, workers) == RawPoolResult.accepted);
        scope (exit)
        {
            atomicStore(gate.release, true);
            cast(void) pool.shutdown(true);
        }
        scheduler.attach(pool);
        scheduler.initialize();
        foreach (_; 0 .. workers)
            assert(pool.submit(RawJob(&block, null, &gate))
                == RawPoolResult.accepted);
        const deadline = MonoTime.currTime + 5.seconds;
        while (atomicLoad(gate.entered) != workers && MonoTime.currTime < deadline)
            Thread.yield();
        assert(atomicLoad(gate.entered) == workers);

        // All executions are gated. Submitted jobs retain immutable queries,
        // even when spare generation metadata could hold another prompt.
        foreach (i; 0 .. workers + 1)
            assert(scheduler.request(queries[i], snapshot, 1.msecs).hasValue);
        assert(scheduler.request("discard glob:missing/*", snapshot, 1.msecs).hasValue);
        assert(scheduler.pending, "requests beyond execution capacity coalesce");
        scheduler.cancel();
        assert(!scheduler.pending);
        auto newest = scheduler.request("glob:src/café.d", snapshot, 1.msecs);
        assert(newest.hasValue && scheduler.pending);
        foreach (i; 0 .. workers + 1)
            assert(scheduler.slots[i].query.source == queries[i],
                "editing and cancellation must not overwrite queued query borrows");

        PickerState!4 state;
        state.open();
        scheduler.poll(state);
        assert(state.rowCount == 0 && state.generation == 0);
        atomicStore(gate.release, true);
        assert(pool.shutdown(true) == RawPoolResult.accepted);
        assert(scheduler.hasInFlight,
            "shutdown does not release contexts before completion dispatch");
        auto last = scheduler.request("glob:docs/café.md", snapshot, 1.msecs);
        assert(last.hasValue && last.value > newest.value && scheduler.pending);
        foreach (i; 0 .. workers + 1)
            assert(scheduler.slots[i].query.source == queries[i],
                "undispatched completions still pin their generation");
        foreach (_; 0 .. 16)
        {
            scheduler.poll(state);
            if (state.generation == last.value && !state.searching)
                break;
        }
        assert(state.error.code == FuzzyErrorCode.none);
        assert(state.generation == last.value && !state.searching);
        assert(state.rowCount == 1 && state.rows[0].corpusIndex == 1);
        assert(!scheduler.hasInFlight);
    }
}

@("picker.scheduler.saturatedPoolFallbackKeepsNewestGeneration")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs, seconds;

    static struct Gate
    {
        shared bool entered;
        shared bool release;
    }
    static void block(void* raw) @trusted nothrow @nogc
    {
        auto gate = cast(Gate*) raw;
        atomicStore(gate.entered, true);
        while (!atomicLoad(gate.release))
            Thread.yield();
    }

    CandidateView[2] candidates;
    candidates[0].id.low = 1;
    candidates[0].path = "src/alpha.d";
    candidates[0].filenameOffset = 4;
    candidates[1].id.low = 2;
    candidates[1].path = "docs/beta.md";
    candidates[1].filenameOffset = 5;
    CandidateSnapshot snapshot;
    snapshot.id.low = 12;
    snapshot.candidates = candidates[];
    alias Scheduler = PickerScheduler!(DefaultFuzzyCaps, 4, 4, 1, 2);
    Scheduler.Pool pool;
    Gate gate;
    auto owner = makeUnique!Scheduler();
    auto scheduler = &owner.get();
    assert(Scheduler.Pool.start(pool, 1) == RawPoolResult.accepted);
    scope (exit)
    {
        atomicStore(gate.release, true);
        cast(void) pool.shutdown(true);
    }
    scheduler.attach(pool);
    scheduler.initialize();
    assert(pool.submit(RawJob(&block, null, &gate)) == RawPoolResult.accepted);
    const deadline = MonoTime.currTime + 5.seconds;
    while (!atomicLoad(gate.entered) && MonoTime.currTime < deadline)
        Thread.yield();
    assert(atomicLoad(gate.entered));

    assert(scheduler.request("alpha glob:src/*.d", snapshot, 1.msecs).hasValue);
    auto fallback = scheduler.request("glob:docs/beta.md", snapshot, 1.msecs);
    assert(fallback.hasValue);
    PickerState!4 state;
    state.open();
    foreach (_; 0 .. 16)
    {
        scheduler.poll(state);
        if (state.generation == fallback.value && !state.searching)
            break;
    }
    assert(state.generation == fallback.value && !state.searching);
    assert(state.rowCount == 1 && state.rows[0].corpusIndex == 1);
    assert(scheduler.hasInFlight, "fallback progresses while a worker job is outstanding");

    assert(scheduler.request("glob:src/alpha.d", snapshot, 1.msecs).hasValue);
    scheduler.cancel();
    auto newest = scheduler.request("glob:docs/beta.md", snapshot, 1.msecs);
    assert(newest.hasValue && scheduler.pending);
    foreach (_; 0 .. 16)
    {
        scheduler.poll(state);
        if (state.generation == newest.value && !state.searching)
            break;
    }
    assert(state.error.code == FuzzyErrorCode.none);
    assert(state.generation == newest.value && !state.searching);
    assert(state.rowCount == 1 && state.rows[0].corpusIndex == 1);
    atomicStore(gate.release, true);
    assert(pool.shutdown(true) == RawPoolResult.accepted);
    scheduler.poll(state);
    assert(state.generation == newest.value && state.rowCount == 1
        && state.rows[0].corpusIndex == 1);
    assert(!scheduler.hasInFlight);
}

@("picker.state.listScrollsThroughADeeperRanking")
@safe pure nothrow @nogc
unittest
{
    // The kept ranking is deeper than the painted window, so moving past the
    // last painted row scrolls instead of stopping. Before the split these
    // were one number and the ranking was simply truncated to what fit —
    // which a file picker never noticed, because typing narrows faster than
    // scrolling, and which grep would have noticed immediately (`PKC17`: a
    // literal needle cannot be narrowed further, so scrolling is the only
    // move left).
    PickerState!64 state;
    state.viewRows = 4;
    state.open();

    RankedResult[20] all;
    foreach (i; 0 .. all.length)
    {
        all[i].corpusIndex = i;
        all[i].id = CandidateId(cast(uint) i);
    }
    state.publish(all[], 1, false);
    assert(state.rowCount == 20, "all 20 kept, not just the painted 4");
    assert(state.visible.length == 4, "only 4 painted");
    assert(state.firstRow == 0);

    // Down inside the window does not scroll.
    state.moveSelection(3);
    assert(state.selection == 3 && state.firstRow == 0);

    // Past its bottom edge scrolls by exactly one, keeping the selection
    // on the last painted row.
    state.moveSelection(1);
    assert(state.selection == 4 && state.firstRow == 1,
        "the window must follow the selection down");
    assert(state.visible[$ - 1].corpusIndex == 4);

    // To the end: the window stops with the last row painted, never past it.
    state.moveSelection(100);
    assert(state.selection == 19);
    assert(state.firstRow == 16, "window pinned to the ranking's tail");
    assert(state.visible.length == 4);

    // And back up.
    state.moveSelection(-100);
    assert(state.selection == 0 && state.firstRow == 0);
}

@("picker.state.horizontalOffsetClampsAndResetsPerQuery")
@safe pure nothrow @nogc
unittest
{
    // `PKL8`. A deep path exhausts the panel before the match is reached,
    // and the row was simply truncated with nothing to reveal the rest.
    PickerState!8 state;
    state.open();
    state.viewCols = 40;
    state.contentCols = 100;

    assert(state.hOverflows);
    assert(state.scrollHorizontal(8) && state.hOffset == 8);
    assert(state.scrollHorizontal(-100) && state.hOffset == 0,
        "clamped at the left edge, not negative");
    assert(!state.scrollHorizontal(-8), "and refuses when already there");

    assert(state.scrollHorizontal(1000));
    assert(state.hOffset == 60, "clamped so the widest row's end is flush");
    assert(!state.scrollHorizontal(8), "and refuses past it");

    // Content that fits does not scroll at all.
    state.contentCols = 20;
    assert(!state.hOverflows);
    assert(!state.scrollHorizontal(8), "nothing to scroll");

    // A new generation is a different set of rows, so an offset carried
    // over would point into text that is no longer there.
    state.contentCols = 100;
    cast(void) state.scrollHorizontal(-1000); // back to the left edge first
    cast(void) state.scrollHorizontal(24);
    assert(state.hOffset == 24);
    RankedResult[1] rows;
    state.publish(rows[], state.generation + 1, false);
    assert(state.hOffset == 0, "a new query starts flush left");
}

@("picker.state.aNewQueryStartsAtTheTopPick")
@safe pure nothrow @nogc
unittest
{
    // `PIK10`. Editing the prompt asks a different question, so the answer
    // is the new first hit — not whichever row the old cursor happened to
    // sit on. `publish`'s preserve-the-selection rule is right only while
    // the query is UNCHANGED (a partial page growing under the cursor).
    PickerState!16 state;
    state.viewRows = 4;
    state.open();

    RankedResult[8] rows;
    foreach (i; 0 .. rows.length)
    {
        rows[i].corpusIndex = i;
        rows[i].id = CandidateId(cast(uint)(100 + i));
    }
    state.publish(rows[], 1, false);
    state.moveSelection(6);
    assert(state.selection == 6 && state.firstRow > 0,
        "the cursor is deep in the list and the window followed it");
    state.contentCols = 200;
    state.viewCols = 40;
    cast(void) state.scrollHorizontal(24);
    assert(state.hOffset == 24);

    state.restartSelection();
    assert(state.selection == 0, "a new query selects the top pick");
    assert(state.firstRow == 0, "and scrolls the window back to it");
    assert(state.hOffset == 0, "and starts flush left");
}
