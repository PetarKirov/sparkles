/** Clock-free deterministic chunked search over immutable candidate snapshots. */
module sparkles.fuzzy.search;

version (unittest) import sparkles.base.unique : makeUnique;

import sparkles.base.text.utf8 : utf8SequenceLength;

import sparkles.fuzzy.common : CandidateView, CorpusId, DefaultFuzzyCaps,
    FuzzyErrorCode, FuzzyExpected, FuzzyLimits, fuzzyErr, fuzzyOk,
    validateCandidate, validateLimits;
import sparkles.fuzzy.match : MatchConfig, MatchKind, MatcherWorkspace,
    Scoring, match;
import sparkles.fuzzy.query : ConstraintWorkspace, QueryStorage,
    evaluateConstraints;
import sparkles.fuzzy.rank : RankContext, RankedResult, TopK, rank;

import sparkles.test_runner.attributes : benchmark;

/// One immutable corpus generation and optional aligned rank signals.
struct CandidateSnapshot
{
    CorpusId id;
    const(CandidateView)[] candidates;
    /// Empty means every candidate uses `RankContext.init`.
    const(RankContext)[] rankContexts;
}

/// Resume token bound to one corpus, query, sink, and accumulator revision.
struct SearchCursor
{
    CorpusId corpus;
    ulong queryGeneration;
    size_t nextOffset;
    ulong sinkEpoch;
    ulong accumulatorRevision;
}

/// Dual deterministic work bounds for one `searchChunk` call.
struct SearchLimits
{
    size_t maxCandidates = 256;
    size_t maxAnalyzedUnits = 64 * 1_024;
}

/// Why a successful chunk returned control to its caller.
enum SearchStop : ubyte
{
    exhausted,
    workLimit,
}

/// Progress and next cursor from one chunk.
struct SearchStatus
{
    SearchStop stop;
    SearchCursor cursor;
    size_t examined;
    size_t chargedUnits;
    size_t analyzedUnits;
    size_t admitted;
}

/** Persistent global best-results sink for one query generation. */
struct SearchAccumulator(size_t Capacity)
if (Capacity > 0)
{
    private TopK!Capacity top;
    private CorpusId corpus_;
    private ulong queryGeneration_;
    private ulong sinkEpoch_;
    private ulong revision_;
    private bool initialized_;

    /// Reset for a new immutable generation and return its initial cursor.
    FuzzyExpected!SearchCursor begin(CorpusId corpus, ulong queryGeneration,
        ulong sinkEpoch, size_t offset, size_t limit)
        @safe pure nothrow @nogc
    {
        if (revision_ == ulong.max)
            return fuzzyErr!SearchCursor(FuzzyErrorCode.arithmeticOverflow);
        auto configured = top.reset(offset, limit);
        if (configured.hasError)
            return fuzzyErr!SearchCursor(configured.error.code,
                configured.error.offset, configured.error.context);
        corpus_ = corpus;
        queryGeneration_ = queryGeneration;
        sinkEpoch_ = sinkEpoch;
        ++revision_;
        initialized_ = true;
        return fuzzyOk(SearchCursor(corpus, queryGeneration, 0, sinkEpoch,
            revision_));
    }

    FuzzyExpected!size_t page(size_t N)(ref RankedResult[N] output)
        @safe pure nothrow @nogc
        => top.page(output);

    ulong revision() const @safe pure nothrow @nogc => revision_;
    bool initialized() const @safe pure nothrow @nogc => initialized_;

private:
    bool accepts(in SearchCursor cursor) const @safe pure nothrow @nogc
    {
        return initialized_ && cursor.corpus == corpus_
            && cursor.queryGeneration == queryGeneration_
            && cursor.sinkEpoch == sinkEpoch_
            && cursor.accumulatorRevision == revision_;
    }

    FuzzyExpected!void offer(in RankedResult result)
        @safe pure nothrow @nogc
    {
        auto offered = top.offer(result);
        return offered.hasError
            ? fuzzyErr!void(offered.error.code, offered.error.offset,
                offered.error.context)
            : fuzzyOk();
    }

    FuzzyExpected!void commit(ref SearchCursor cursor)
        @safe pure nothrow @nogc
    {
        if (revision_ == ulong.max)
            return fuzzyErr!void(FuzzyErrorCode.arithmeticOverflow);
        ++revision_;
        cursor.accumulatorRevision = revision_;
        return fuzzyOk();
    }
}

/**
Advance a search without clocks, callbacks, atomics, or allocation.

The analyzed-unit guard uses a conservative per-scalar expansion bound before
starting a candidate, then reports actual emitted units. This keeps the hard
work limit even for compatibility-normalization and full-fold expansions.
*/
FuzzyExpected!SearchStatus searchChunk(Caps = DefaultFuzzyCaps,
    size_t Capacity)(in QueryStorage!Caps query,
    in CandidateSnapshot snapshot, SearchCursor cursor,
    SearchLimits searchLimits, MatchConfig matchConfig, Scoring scoring,
    FuzzyLimits fuzzyLimits, ref SearchAccumulator!Capacity accumulator,
    ref MatcherWorkspace!Caps matcher,
    ref ConstraintWorkspace!Caps constraints) @safe pure nothrow @nogc
{
    auto checkedLimits = validateLimits!Caps(fuzzyLimits);
    if (checkedLimits.hasError)
        return fuzzyErr!SearchStatus(checkedLimits.error.code,
            checkedLimits.error.offset, checkedLimits.error.context);
    if (!accumulator.accepts(cursor) || cursor.corpus != snapshot.id
        || cursor.nextOffset > snapshot.candidates.length)
        return fuzzyErr!SearchStatus(FuzzyErrorCode.invalidCursor,
            cursor.nextOffset);
    if (searchLimits.maxCandidates == 0
        || searchLimits.maxAnalyzedUnits == 0
        || (snapshot.rankContexts.length != 0
            && snapshot.rankContexts.length != snapshot.candidates.length))
        return fuzzyErr!SearchStatus(FuzzyErrorCode.invalidConfiguration);

    SearchStatus status;
    status.cursor = cursor;
    while (status.cursor.nextOffset < snapshot.candidates.length)
    {
        if (status.examined == searchLimits.maxCandidates)
        {
            status.stop = SearchStop.workLimit;
            break;
        }
        const candidate = snapshot.candidates[status.cursor.nextOffset];
        auto checkedCandidate = validateCandidate!Caps(candidate,
            checkedLimits.value);
        if (checkedCandidate.hasError)
            return fuzzyErr!SearchStatus(checkedCandidate.error.code,
                checkedCandidate.error.offset,
                checkedCandidate.error.context);
        const workBound = analyzedUnitUpperBound(candidate.path,
            checkedLimits.value.maxCandidateUnits);
        if (workBound > searchLimits.maxAnalyzedUnits - status.chargedUnits)
        {
            // With zero progress the caller's retry would start at the same
            // candidate with the same fresh budget and stop again — the
            // documented drive-to-exhaustion loop would spin forever. Report
            // the impossible configuration instead of livelocking.
            if (status.examined == 0)
                return fuzzyErr!SearchStatus(
                    FuzzyErrorCode.invalidConfiguration,
                    status.cursor.nextOffset,
                    "maxAnalyzedUnits is below one candidate's work bound");
            status.stop = SearchStop.workLimit;
            break;
        }
        status.chargedUnits += workBound;

        auto acceptedConstraints = evaluateConstraints(query, candidate,
            constraints, checkedLimits.value);
        if (acceptedConstraints.hasError)
            return fuzzyErr!SearchStatus(acceptedConstraints.error.code,
                acceptedConstraints.error.offset,
                acceptedConstraints.error.context);
        if (acceptedConstraints.value)
        {
            auto matched = match(query, candidate, matchConfig, scoring,
                checkedLimits.value, matcher);
            if (matched.hasError)
                return fuzzyErr!SearchStatus(matched.error.code,
                    matched.error.offset, matched.error.context);
            status.analyzedUnits += matched.value.analyzedUnits;
            if (matched.value.kind != MatchKind.rejected)
            {
                RankContext context;
                if (snapshot.rankContexts.length != 0)
                    context = snapshot.rankContexts[status.cursor.nextOffset];
                auto ranked = rank(candidate, matched.value, context,
                    status.cursor.nextOffset);
                if (ranked.hasError)
                    return fuzzyErr!SearchStatus(ranked.error.code,
                        ranked.error.offset, ranked.error.context);
                auto offered = accumulator.offer(ranked.value);
                if (offered.hasError)
                    return fuzzyErr!SearchStatus(offered.error.code,
                        offered.error.offset, offered.error.context);
                ++status.admitted;
            }
        }
        ++status.examined;
        ++status.cursor.nextOffset;
    }

    if (status.cursor.nextOffset == snapshot.candidates.length)
        status.stop = SearchStop.exhausted;
    if (status.examined != 0)
    {
        auto committed = accumulator.commit(status.cursor);
        if (committed.hasError)
            return fuzzyErr!SearchStatus(committed.error.code,
                committed.error.offset, committed.error.context);
    }
    return fuzzyOk(status);
}

/// Default-policy convenience overload.
FuzzyExpected!SearchStatus searchChunk(Caps = DefaultFuzzyCaps,
    size_t Capacity)(in QueryStorage!Caps query,
    in CandidateSnapshot snapshot, SearchCursor cursor,
    SearchLimits limits, ref SearchAccumulator!Capacity accumulator,
    ref MatcherWorkspace!Caps matcher,
    ref ConstraintWorkspace!Caps constraints) @safe pure nothrow @nogc
{
    return searchChunk(query, snapshot, cursor, limits, MatchConfig.init,
        Scoring.init, FuzzyLimits.init, accumulator, matcher, constraints);
}

private size_t analyzedUnitUpperBound(scope const(char)[] source,
    size_t capacity) @safe pure nothrow @nogc
{
    size_t result;
    size_t at;
    while (at < source.length)
    {
        const first = cast(ubyte) source[at];
        size_t contribution = first < 0x80 ? 1 : 64;
        auto length = first < 0x80 ? 1 : utf8SequenceLength(source, at);
        if (length == 0)
        {
            length = 1;
            contribution = 1;
        }
        if (result > capacity - (contribution < capacity
                ? contribution : capacity))
            return capacity;
        result += contribution;
        if (result >= capacity)
            return capacity;
        at += length;
    }
    return result;
}

@("fuzzy.search.chunkPartitionsAreEquivalent")
@safe pure nothrow @nogc
unittest
{
    import sparkles.fuzzy.query : parseQuery;

    auto query = parseQuery("src");
    CandidateView[5] candidates;
    static immutable names = ["src/a.d", "other.d", "src/b.d",
        "xsrc.d", "none.d"];
    foreach (i; 0 .. candidates.length)
    {
        candidates[i].id.low = i + 1;
        candidates[i].path = names[i];
        candidates[i].recencyKey = cast(long) i;
    }
    CandidateSnapshot snapshot;
    snapshot.id.low = 42;
    snapshot.candidates = candidates[];

    SearchAccumulator!5 chunked;
    auto cursor = chunked.begin(snapshot.id, 7, 3, 0, 5).value;
    auto matcherOwner = makeUnique!(MatcherWorkspace!())();
    ref MatcherWorkspace!() matcher() => matcherOwner.get();
    ConstraintWorkspace!() constraints;
    SearchLimits limits;
    limits.maxCandidates = 2;
    limits.maxAnalyzedUnits = 1_000;
    for (;;)
    {
        auto status = searchChunk(query.value, snapshot, cursor, limits,
            chunked, matcher, constraints);
        assert(status.hasValue);
        cursor = status.value.cursor;
        if (status.value.stop == SearchStop.exhausted)
            break;
    }

    SearchAccumulator!5 whole;
    auto wholeCursor = whole.begin(snapshot.id, 7, 4, 0, 5).value;
    limits.maxCandidates = 10;
    auto complete = searchChunk(query.value, snapshot, wholeCursor, limits,
        whole, matcher, constraints);
    assert(complete.hasValue && complete.value.stop == SearchStop.exhausted);

    RankedResult[5] chunkedPage;
    RankedResult[5] wholePage;
    const chunkedCount = chunked.page(chunkedPage).value;
    const wholeCount = whole.page(wholePage).value;
    assert(chunkedCount == wholeCount);
    foreach (i; 0 .. chunkedCount)
        assert(chunkedPage[i].id == wholePage[i].id);
}

@("fuzzy.search.zeroProgressWorkLimitIsAnError")
@safe pure nothrow @nogc
unittest
{
    import sparkles.fuzzy.query : parseQuery;

    auto query = parseQuery("src");
    CandidateView[2] candidates;
    candidates[0].id.low = 1;
    candidates[0].path = "src/a.d";
    candidates[1].id.low = 2;
    candidates[1].path = "src/some/deeply/nested/candidate/path.d";
    CandidateSnapshot snapshot;
    snapshot.id.low = 9;
    snapshot.candidates = candidates[];
    auto matcherOwner = makeUnique!(MatcherWorkspace!())();
    ref MatcherWorkspace!() matcher() => matcherOwner.get();
    ConstraintWorkspace!() constraints;

    // A budget below the very first candidate's work bound is unsatisfiable:
    // an error, not a zero-progress `workLimit`.
    SearchAccumulator!2 accumulator;
    auto cursor = accumulator.begin(snapshot.id, 1, 1, 0, 2).value;
    SearchLimits limits;
    limits.maxCandidates = 4;
    limits.maxAnalyzedUnits = 4;
    auto result = searchChunk(query.value, snapshot, cursor, limits,
        accumulator, matcher, constraints);
    assert(result.hasError
        && result.error.code == FuzzyErrorCode.invalidConfiguration
        && result.error.offset == 0);

    // A budget that admits the first candidate but not the second still makes
    // progress, then reports the poison candidate on the next call instead of
    // spinning on it.
    SearchAccumulator!2 partial;
    auto partialCursor = partial.begin(snapshot.id, 2, 2, 0, 2).value;
    limits.maxAnalyzedUnits = candidates[0].path.length;
    auto first = searchChunk(query.value, snapshot, partialCursor, limits,
        partial, matcher, constraints);
    assert(first.hasValue && first.value.stop == SearchStop.workLimit
        && first.value.examined == 1);
    auto second = searchChunk(query.value, snapshot, first.value.cursor,
        limits, partial, matcher, constraints);
    assert(second.hasError
        && second.error.code == FuzzyErrorCode.invalidConfiguration
        && second.error.offset == 1);
}

@("fuzzy.search.rejectsStaleCursor")
@safe pure nothrow @nogc
unittest
{
    import sparkles.fuzzy.query : parseQuery;

    auto query = parseQuery("ab");
    CandidateSnapshot snapshot;
    snapshot.id.low = 1;
    SearchAccumulator!2 accumulator;
    auto cursor = accumulator.begin(snapshot.id, 1, 1, 0, 2).value;
    ++cursor.accumulatorRevision;
    auto matcherOwner = makeUnique!(MatcherWorkspace!())();
    ref MatcherWorkspace!() matcher() => matcherOwner.get();
    ConstraintWorkspace!() constraints;
    auto result = searchChunk(query.value, snapshot, cursor,
        SearchLimits.init, accumulator, matcher, constraints);
    assert(result.hasError
        && result.error.code == FuzzyErrorCode.invalidCursor);
}

@("fuzzy.search.bench.completeCandidateGeneration")
@benchmark @safe
unittest
{
    import sparkles.fuzzy.query : parseQuery;
    import sparkles.test_runner.bench : benchIter, blackBox;

    class Context
    {
        bool alternate;
        ulong generation;
        CandidateView[1] candidates;
        CandidateSnapshot snapshot;
        SearchAccumulator!8 accumulator;
        MatcherWorkspace!() matcher;
        ConstraintWorkspace!() constraints;
        RankedResult[8] page;
    }
    auto context = new Context;
    context.candidates[0].id.low = 1;
    context.candidates[0].path
        = "libs/base/src/sparkles/base/text/unicode_tables.d";
    context.candidates[0].filenameOffset = 33;
    context.snapshot.id.low = 91;
    context.snapshot.candidates = context.candidates[];

    benchIter({
        context.alternate = !context.alternate;
        ++context.generation;
        const prompt = context.alternate ? "unicode table" : "unicode tables";
        auto query = parseQuery(blackBox(prompt));
        assert(query.hasValue);
        auto cursor = context.accumulator.begin(context.snapshot.id,
            context.generation, context.generation, 0,
            context.page.length);
        assert(cursor.hasValue);
        SearchLimits limits;
        limits.maxCandidates = 1;
        limits.maxAnalyzedUnits = DefaultFuzzyCaps.maxCandidateUnits;
        auto status = searchChunk(query.value, context.snapshot, cursor.value,
            limits, context.accumulator, context.matcher,
            context.constraints);
        assert(status.hasValue && status.value.stop == SearchStop.exhausted);
        auto count = context.accumulator.page(context.page);
        assert(count.hasValue && count.value == 1);
        blackBox(context.page[0].score.total);
    }, ["profile": "codePath", "tier": "parse+search+rank+page",
        "construction": "generation-setup-included",
        "corpus": "one-candidate-keystroke"]);
}
