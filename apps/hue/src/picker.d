/** Presentation-free picker state and generation-safe bounded scheduler. */
module picker;

import core.atomic : MemoryOrder, atomicLoad, atomicStore;
import core.time : Duration, MonoTime;

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
import sparkles.ui.state : ScrollState;

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
        char[4] encoded = void;
        const count = encodeUtf8(value, encoded);
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
        --length_;
        while (length_ != 0
            && (cast(ubyte) bytes[length_] & 0xC0) == 0x80)
            --length_;
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
    ScrollState scroll;
    ulong generation;
    bool active;
    bool searching;
    bool showScoreDebug;
    FuzzyError error;

    const(RankedResult)[] rows() const return scope @trusted pure nothrow @nogc
        => rows_[0 .. rowCount_];
    size_t rowCount() const @safe pure nothrow @nogc => rowCount_;

    void open() @safe pure nothrow @nogc
    {
        prompt.start();
        rowCount_ = 0;
        selection = 0;
        scroll = ScrollState.init;
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
    MatcherWorkspace!Caps matcher;
    ConstraintWorkspace!Caps constraints;
    FuzzyLimits fuzzyLimits;
    MatchConfig matchConfig;
    Scoring scoring;
    Duration budget;
    ulong generation;
    shared(ulong)* publishedGeneration;
    FuzzyError error;
    bool finished;
    bool cancelled;
    bool ready;
    GenerationState state;
}

/**
Closure-free picker scheduler over `RawCpuPool` with synchronous degradation.

Query bytes and result sinks live inside address-stable generation slots. New
requests publish their generation with release ordering and never overwrite a
running slot; workers acquire-load before each candidate-sized chunk. When all
slots are busy, the latest prompt is coalesced in a separate fixed buffer.
*/
struct PickerScheduler(Caps = DefaultFuzzyCaps, size_t ResultCapacity = 64,
    size_t SlotCount = 4, size_t QueueCapacity = 32,
    size_t CompletionCapacity = QueueCapacity)
if (ResultCapacity > 0 && SlotCount > 1)
{
    @disable this(this);

    alias Pool = RawCpuPool!(QueueCapacity, CompletionCapacity);
    private GenerationSlot!(Caps, ResultCapacity)[SlotCount] slots;
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

    /// Attach a started pool. Null/unstarted/saturated pools degrade safely.
    void attach(ref Pool value) @safe nothrow @nogc
    {
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
                slot.state = GenerationState.idle;
                continue;
            }
            if (slot.error.code != FuzzyErrorCode.none)
            {
                state.error = slot.error;
                state.searching = false;
                state.generation = slot.generation;
                slot.state = GenerationState.idle;
                continue;
            }

            RankedResult[ResultCapacity] page = void;
            auto pageResult = slot.accumulator.page(page);
            if (pageResult.hasError)
            {
                state.error = pageResult.error;
                state.searching = false;
                slot.state = GenerationState.idle;
                continue;
            }
            state.publish(page[0 .. pageResult.value], slot.generation,
                !slot.finished);
            if (slot.finished)
                slot.state = GenerationState.idle;
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
    void launchPending(ulong generation) @trusted nothrow @nogc
    {
        if (!pending)
            return;
        foreach (ref slot; slots)
        {
            if (slot.state != GenerationState.idle)
                continue;
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
            slot.error = FuzzyError.init;
            slot.finished = false;
            slot.cancelled = false;
            slot.ready = false;
            slot.state = GenerationState.running;

            QueryParseOptions options;
            options.limits = fuzzyLimits;
            auto parsed = parseQuery!Caps(slot.prompt[0 .. slot.promptLength],
                options);
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
            slot.accumulator, slot.matcher, slot.constraints);
        if (status.hasError)
        {
            slot.error = status.error;
            slot.finished = true;
            return;
        }
        slot.cursor = status.value.cursor;
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

private size_t encodeUtf8(dchar value, ref char[4] output)
    @safe pure nothrow @nogc
{
    if (value < 0x20 || value == 0x7F || value > 0x10FFFF
        || (value >= 0xD800 && value <= 0xDFFF))
        return 0;
    if (value <= 0x7F)
    {
        output[0] = cast(char) value;
        return 1;
    }
    if (value <= 0x7FF)
    {
        output[0] = cast(char)(0xC0 | value >> 6);
        output[1] = cast(char)(0x80 | (value & 0x3F));
        return 2;
    }
    if (value <= 0xFFFF)
    {
        output[0] = cast(char)(0xE0 | value >> 12);
        output[1] = cast(char)(0x80 | (value >> 6 & 0x3F));
        output[2] = cast(char)(0x80 | (value & 0x3F));
        return 3;
    }
    output[0] = cast(char)(0xF0 | value >> 18);
    output[1] = cast(char)(0x80 | (value >> 12 & 0x3F));
    output[2] = cast(char)(0x80 | (value >> 6 & 0x3F));
    output[3] = cast(char)(0x80 | (value & 0x3F));
    return 4;
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

    // Heap, not stack: a scheduler is four generation slots of matcher
    // workspace (~3 MiB), and a test runs on a worker thread — 512 KiB of
    // stack on macOS.
    auto scheduler = new PickerScheduler!(DefaultFuzzyCaps, 4);
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

    auto scheduler = new PickerScheduler!(DefaultFuzzyCaps, 4); // see above
    scheduler.attach(pool);
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
