/** Deterministic composite ranking and bounded global top-K selection. */
module sparkles.fuzzy.rank;

import sparkles.fuzzy.common : CandidateId, CandidateView, FuzzyErrorCode,
    FuzzyExpected, GitStatus, PathFlavor, fuzzyErr, fuzzyOk,
    isPathSeparator;
import sparkles.fuzzy.match : MatchKind, MatchOutcome;

import sparkles.test_runner.attributes : benchmark;

/// Caller-supplied non-text signals for one candidate.
struct RankContext
{
    int frecencyPoints;
    int accessPoints;
    int modificationPoints;
    int comboBoost;
    int directoryDistance;
    size_t commonSuffixUnits;
    size_t queryPathUnits;
    bool currentFile;
}

/// Every additive term used to produce a ranked result.
struct ScoreBreakdown
{
    long base;
    long frecency;
    long gitModified;
    long directoryDistance;
    long filename;
    long currentFilePenalty;
    long combo;
    long pathAlignment;
    long access;
    long modification;
    long total;
    MatchKind matchKind;
}

/// By-value sortable result; `corpusIndex` resolves into the pinned snapshot.
struct RankedResult
{
    CandidateId id;
    size_t corpusIndex;
    long recencyKey;
    ScoreBreakdown score;
}

/**
Compute the negated directory-tree distance used by `RankContext`.

Offsets identify the first filename byte and must follow a separator (or be
zero). Segment comparison is ASCII-case-insensitive for Windows paths. The
result is clamped to `[-20, 0]`.
*/
FuzzyExpected!int directoryDistance(scope const(char)[] candidatePath,
    size_t candidateFilenameOffset, scope const(char)[] currentPath,
    size_t currentFilenameOffset, PathFlavor flavor)
    @safe pure nothrow @nogc
{
    if (flavor != PathFlavor.unix && flavor != PathFlavor.windows)
        return fuzzyErr!int(FuzzyErrorCode.invalidConfiguration);
    if (!validFilenameOffset(candidatePath, candidateFilenameOffset, flavor))
        return fuzzyErr!int(FuzzyErrorCode.invalidCandidate,
            candidateFilenameOffset);
    if (!validFilenameOffset(currentPath, currentFilenameOffset, flavor))
        return fuzzyErr!int(FuzzyErrorCode.invalidCandidate,
            currentFilenameOffset);
    const candidateDepth = segmentDepth(candidatePath,
        candidateFilenameOffset, flavor);
    const currentDepth = segmentDepth(currentPath, currentFilenameOffset,
        flavor);
    const common = commonDirectoryDepth(candidatePath,
        candidateFilenameOffset, currentPath, currentFilenameOffset, flavor);
    const candidateExtra = candidateDepth - common;
    const currentExtra = currentDepth - common;
    if (candidateExtra > 20 || currentExtra > 20 - candidateExtra)
        return fuzzyOk(-20);
    return fuzzyOk(-cast(int)(candidateExtra + currentExtra));
}

/** Compose all rank terms with checked signed arithmetic. */
FuzzyExpected!RankedResult rank(in CandidateView candidate,
    in MatchOutcome matched, in RankContext context,
    size_t corpusIndex = 0) @safe pure nothrow @nogc
{
    if (matched.kind == MatchKind.rejected
        || (matched.kind != MatchKind.matched
            && matched.kind != MatchKind.matchedFallback
            && matched.kind != MatchKind.noFuzzyTerms)
        || (matched.kind != MatchKind.noFuzzyTerms && matched.score == 0)
        || (matched.kind == MatchKind.noFuzzyTerms && matched.score != 0))
        return fuzzyErr!RankedResult(FuzzyErrorCode.invalidCandidate);
    if (!validFilenameOffset(candidate.path, candidate.filenameOffset,
            candidate.pathFlavor)
        || (cast(ushort) candidate.gitStatus & ~knownGitStatusMask) != 0)
        return fuzzyErr!RankedResult(FuzzyErrorCode.invalidCandidate,
            candidate.filenameOffset);
    if (context.frecencyPoints < 0 || context.frecencyPoints > 100_000
        || context.accessPoints < 0 || context.accessPoints > 1_000_000
        || context.modificationPoints < 0
        || context.modificationPoints > 1_000_000
        || context.comboBoost < 0 || context.comboBoost > 1_000_000)
        return fuzzyErr!RankedResult(FuzzyErrorCode.invalidConfiguration);

    RankedResult result;
    result.id = candidate.id;
    result.corpusIndex = corpusIndex;
    result.recencyKey = candidate.recencyKey;
    ref score = result.score;
    score.matchKind = matched.kind;

    if (matched.kind == MatchKind.noFuzzyTerms)
    {
        score.access = context.accessPoints;
        score.modification = context.modificationPoints;
        score.combo = context.comboBoost;
        auto first = checkedAdd(score.access, score.modification);
        if (first.hasError)
            return fuzzyErr!RankedResult(first.error.code);
        auto total = checkedAdd(first.value, score.combo);
        if (total.hasError)
            return fuzzyErr!RankedResult(total.error.code);
        score.total = total.value;
        return fuzzyOk(result);
    }

    score.base = matched.score;
    auto percentage = percent(score.base, context.frecencyPoints);
    if (percentage.hasError)
        return fuzzyErr!RankedResult(percentage.error.code);
    score.frecency = percentage.value;

    if ((cast(ushort) candidate.gitStatus
            & cast(ushort) GitStatus.modified) != 0)
        score.gitModified = percent(score.base, 15).value;

    score.directoryDistance = context.directoryDistance > 0 ? 0
        : context.directoryDistance < -20 ? -20 : context.directoryDistance;

    if (matched.exactFilename)
        score.filename = percent(score.base, 40).value;
    else if (matched.allInFilename)
    {
        score.filename = percent(score.base, 40).value;
        if (score.filename > 30)
            score.filename = 30;
    }
    else if (isSpecialStarter(candidate))
        score.filename = percent(score.base, 5).value;

    if (context.currentFile)
        score.currentFilePenalty = -percent(score.base, 25).value;
    score.combo = context.comboBoost;

    const alignmentThreshold = context.queryPathUnits / 10 * 3
        + ((context.queryPathUnits % 10) * 3 + 9) / 10;
    if (matched.queryContainsSeparator && context.queryPathUnits != 0
        && context.commonSuffixUnits > 10
        && context.commonSuffixUnits >= alignmentThreshold)
    {
        if (context.queryPathUnits > long.max)
            return fuzzyErr!RankedResult(FuzzyErrorCode.arithmeticOverflow);
        if (context.commonSuffixUnits > long.max / score.base)
            return fuzzyErr!RankedResult(FuzzyErrorCode.arithmeticOverflow);
        score.pathAlignment = score.base
            * cast(long) context.commonSuffixUnits
            / cast(long) context.queryPathUnits;
    }

    long total;
    foreach (term; [score.base, score.frecency, score.gitModified,
            score.directoryDistance, score.filename,
            score.currentFilePenalty, score.combo, score.pathAlignment])
    {
        auto sum = checkedAdd(total, term);
        if (sum.hasError)
            return fuzzyErr!RankedResult(sum.error.code);
        total = sum.value;
    }
    score.total = total;
    return fuzzyOk(result);
}

/// True when `left` precedes `right` in the package's total order.
bool ranksBefore(in RankedResult left, in RankedResult right)
    @safe pure nothrow @nogc
{
    if (left.score.total != right.score.total)
        return left.score.total > right.score.total;
    if (left.recencyKey != right.recencyKey)
        return left.recencyKey > right.recencyKey;
    return left.id.opCmp(right.id) < 0;
}

/**
Fixed min-heap retaining the globally best `offset + limit` results.

`page` copies and sorts a snapshot, so publishing a partial page does not
disturb later offers to the same generation.
*/
struct TopK(size_t Capacity)
if (Capacity > 0)
{
    private RankedResult[Capacity] heap = void;
    private RankedResult[Capacity] ordered = void;
    private size_t count_;
    private size_t keep_;
    private size_t offset_;
    private size_t limit_;
    private ulong revision_;

    FuzzyExpected!void reset(size_t offset, size_t limit)
        @safe pure nothrow @nogc
    {
        if (limit == 0)
            return fuzzyErr!void(FuzzyErrorCode.invalidConfiguration);
        if (offset > size_t.max - limit)
            return fuzzyErr!void(FuzzyErrorCode.arithmeticOverflow);
        if (offset + limit > Capacity)
            return fuzzyErr!void(FuzzyErrorCode.outputFull, offset + limit);
        if (revision_ == ulong.max)
            return fuzzyErr!void(FuzzyErrorCode.arithmeticOverflow);
        count_ = 0;
        keep_ = offset + limit;
        offset_ = offset;
        limit_ = limit;
        ++revision_;
        return fuzzyOk();
    }

    /// Offer one result in `O(log(offset + limit))`.
    FuzzyExpected!bool offer(in RankedResult result)
        @safe pure nothrow @nogc
    {
        if (keep_ == 0)
            return fuzzyOk(false);
        if (count_ < keep_)
        {
            if (revision_ == ulong.max)
                return fuzzyErr!bool(FuzzyErrorCode.arithmeticOverflow);
            heap[count_] = result;
            siftUp(count_++);
            ++revision_;
            return fuzzyOk(true);
        }
        if (!ranksBefore(result, heap[0]))
            return fuzzyOk(false);
        if (revision_ == ulong.max)
            return fuzzyErr!bool(FuzzyErrorCode.arithmeticOverflow);
        heap[0] = result;
        siftDown(0);
        ++revision_;
        return fuzzyOk(true);
    }

    /** Copy the requested, best-first page into caller storage. */
    FuzzyExpected!size_t page(size_t N)(ref RankedResult[N] output)
        @safe pure nothrow @nogc
    {
        if (keep_ == 0)
            return fuzzyErr!size_t(FuzzyErrorCode.invalidConfiguration);
        const available = count_ > offset_ ? count_ - offset_ : 0;
        size_t wanted = available < limit_ ? available : limit_;
        if (wanted > N)
            return fuzzyErr!size_t(FuzzyErrorCode.outputFull, wanted);
        foreach (i; 0 .. count_)
            ordered[i] = heap[i];
        insertionSort(ordered[0 .. count_]);
        foreach (i; 0 .. wanted)
            output[i] = ordered[offset_ + i];
        return fuzzyOk(wanted);
    }

    size_t count() const @safe pure nothrow @nogc => count_;
    size_t retainedCapacity() const @safe pure nothrow @nogc => keep_;
    ulong revision() const @safe pure nothrow @nogc => revision_;

private:
    void siftUp(size_t at) @safe pure nothrow @nogc
    {
        while (at != 0)
        {
            const parent = (at - 1) / 2;
            if (!ranksBefore(heap[parent], heap[at]))
                break;
            swap(heap[parent], heap[at]);
            at = parent;
        }
    }

    void siftDown(size_t at) @safe pure nothrow @nogc
    {
        for (;;)
        {
            const left = at * 2 + 1;
            if (left >= count_)
                return;
            const right = left + 1;
            size_t worse = left;
            if (right < count_ && ranksBefore(heap[left], heap[right]))
                worse = right;
            if (!ranksBefore(heap[at], heap[worse]))
                return;
            swap(heap[at], heap[worse]);
            at = worse;
        }
    }
}

private void insertionSort(scope RankedResult[] values)
    @safe pure nothrow @nogc
{
    foreach (i; 1 .. values.length)
    {
        const value = values[i];
        size_t at = i;
        while (at != 0 && ranksBefore(value, values[at - 1]))
        {
            values[at] = values[at - 1];
            --at;
        }
        values[at] = value;
    }
}

private void swap(ref RankedResult left, ref RankedResult right)
    @safe pure nothrow @nogc
{
    const temporary = left;
    left = right;
    right = temporary;
}

private FuzzyExpected!long percent(long base, int points)
    @safe pure nothrow @nogc
{
    if (points != 0 && base > long.max / points)
        return fuzzyErr!long(FuzzyErrorCode.arithmeticOverflow);
    return fuzzyOk(base * points / 100);
}

private FuzzyExpected!long checkedAdd(long left, long right)
    @safe pure nothrow @nogc
{
    if ((right > 0 && left > long.max - right)
        || (right < 0 && left < long.min - right))
        return fuzzyErr!long(FuzzyErrorCode.arithmeticOverflow);
    return fuzzyOk(left + right);
}

private bool isSpecialStarter(in CandidateView candidate)
    @safe pure nothrow @nogc
{
    const filename = candidate.path[candidate.filenameOffset .. $];
    foreach (name; ["mod.rs", "index.ts", "index.js", "__init__.py",
            "main.go", "main.rs", "main.c", "main.cpp", "app.d"])
        if (filename == name)
            return true;
    return false;
}

private bool validFilenameOffset(scope const(char)[] path, size_t offset,
    PathFlavor flavor) @safe pure nothrow @nogc
{
    return (flavor == PathFlavor.unix || flavor == PathFlavor.windows)
        && offset <= path.length && (offset == 0
        || isPathSeparator(path[offset - 1], flavor));
}

private enum ushort knownGitStatusMask = cast(ushort) GitStatus.modified
    | cast(ushort) GitStatus.untracked
    | cast(ushort) GitStatus.staged
    | cast(ushort) GitStatus.ignored
    | cast(ushort) GitStatus.clean;

private size_t segmentDepth(scope const(char)[] path, size_t limit,
    PathFlavor flavor) @safe pure nothrow @nogc
{
    size_t at;
    size_t result;
    size_t start;
    size_t end;
    while (nextSegment(path, limit, flavor, at, start, end))
        ++result;
    return result;
}

private size_t commonDirectoryDepth(scope const(char)[] left,
    size_t leftLimit, scope const(char)[] right, size_t rightLimit,
    PathFlavor flavor) @safe pure nothrow @nogc
{
    size_t leftAt;
    size_t rightAt;
    size_t result;
    size_t leftStart;
    size_t leftEnd;
    size_t rightStart;
    size_t rightEnd;
    while (nextSegment(left, leftLimit, flavor, leftAt, leftStart, leftEnd)
        && nextSegment(right, rightLimit, flavor, rightAt,
            rightStart, rightEnd))
    {
        if (!segmentEqual(left[leftStart .. leftEnd],
                right[rightStart .. rightEnd], flavor))
            break;
        ++result;
    }
    return result;
}

private bool nextSegment(scope const(char)[] path, size_t limit,
    PathFlavor flavor, ref size_t at, out size_t start, out size_t end)
    @safe pure nothrow @nogc
{
    while (at < limit && isPathSeparator(path[at], flavor))
        ++at;
    if (at == limit)
        return false;
    start = at;
    while (at < limit && !isPathSeparator(path[at], flavor))
        ++at;
    end = at;
    return true;
}

private bool segmentEqual(scope const(char)[] left,
    scope const(char)[] right, PathFlavor flavor)
    @safe pure nothrow @nogc
{
    if (left.length != right.length)
        return false;
    foreach (i; 0 .. left.length)
    {
        char a = left[i];
        char b = right[i];
        if (flavor == PathFlavor.windows)
        {
            if (a >= 'A' && a <= 'Z')
                a = cast(char)(a + ('a' - 'A'));
            if (b >= 'A' && b <= 'Z')
                b = cast(char)(b + ('a' - 'A'));
        }
        if (a != b)
            return false;
    }
    return true;
}

@("fuzzy.rank.breakdownAndTotalOrder")
@safe pure nothrow @nogc
unittest
{
    CandidateView candidate;
    candidate.id.low = 2;
    candidate.path = "src/main.rs";
    candidate.filenameOffset = 4;
    candidate.gitStatus = GitStatus.modified;
    candidate.recencyKey = 7;
    MatchOutcome matched;
    matched.kind = MatchKind.matched;
    matched.score = 100;
    matched.allInFilename = true;
    RankContext context;
    context.frecencyPoints = 10;
    context.comboBoost = 3;
    context.directoryDistance = -4;
    context.currentFile = true;
    auto result = rank(candidate, matched, context);
    assert(result.hasValue);
    assert(result.value.score.frecency == 10);
    assert(result.value.score.gitModified == 15);
    assert(result.value.score.filename == 30);
    assert(result.value.score.currentFilePenalty == -25);
    assert(result.value.score.total == 129);

    assert(directoryDistance("src/core/app.d", 9,
        "src/ui/current.d", 7, PathFlavor.unix).value == -2);
    assert(directoryDistance("SRC\\UI\\app.d", 7,
        "src\\ui\\current.d", 7, PathFlavor.windows).value == 0);
    assert(directoryDistance("a", 0, "b", 0,
        cast(PathFlavor) ubyte.max).error.code
        == FuzzyErrorCode.invalidConfiguration);

    matched.kind = cast(MatchKind) ubyte.max;
    assert(rank(candidate, matched, context).error.code
        == FuzzyErrorCode.invalidCandidate);
}

@("fuzzy.rank.topKPaginationIsGlobal")
@safe pure nothrow @nogc
unittest
{
    TopK!5 top;
    assert(!top.reset(1, 2).hasError);
    foreach (value; [10L, 50L, 30L, 40L, 20L])
    {
        RankedResult result;
        result.id.low = cast(ulong) value;
        result.score.total = value;
        assert(!top.offer(result).hasError);
    }
    RankedResult[2] page;
    auto count = top.page(page);
    assert(count.hasValue && count.value == 2);
    assert(page[0].score.total == 40);
    assert(page[1].score.total == 30);

    TopK!5 overflow;
    assert(overflow.reset(size_t.max, 2).error.code
        == FuzzyErrorCode.arithmeticOverflow);
}

@("fuzzy.rank.topKIsIndependentOfIterationOrder")
@safe pure nothrow @nogc
unittest
{
    RankedResult[6] values;
    foreach (i; 0 .. values.length)
    {
        values[i].id.low = i + 1;
        values[i].score.total = cast(long)(i / 2);
        values[i].recencyKey = cast(long)(5 - i % 3);
    }
    auto expected = values;
    insertionSort(expected[]);
    size_t[6] order = [0, 1, 2, 3, 4, 5];
    do
    {
        foreach (offset; 0 .. values.length)
        foreach (limit; 1 .. values.length - offset + 1)
        {
            TopK!6 top;
            assert(!top.reset(offset, limit).hasError);
            foreach (at; order)
                assert(!top.offer(values[at]).hasError);
            RankedResult[6] page;
            const count = top.page(page).value;
            assert(count == limit);
            foreach (i; 0 .. count)
                assert(page[i].id == expected[offset + i].id);
        }
    }
    while (nextPermutation(order));
}

private bool nextPermutation(ref size_t[6] values)
    @safe pure nothrow @nogc
{
    size_t pivot = values.length - 1;
    while (pivot != 0 && values[pivot - 1] >= values[pivot])
        --pivot;
    if (pivot == 0)
        return false;
    --pivot;
    size_t successor = values.length - 1;
    while (values[successor] <= values[pivot])
        --successor;
    auto temporary = values[pivot];
    values[pivot] = values[successor];
    values[successor] = temporary;
    size_t left = pivot + 1;
    size_t right = values.length - 1;
    while (left < right)
    {
        temporary = values[left];
        values[left++] = values[right];
        values[right--] = temporary;
    }
    return true;
}

@("fuzzy.rank.bench.topKGeneration")
@benchmark @safe
unittest
{
    import sparkles.test_runner.bench : benchIter, blackBox;

    class Context
    {
        TopK!64 top;
        RankedResult[64] values;
        RankedResult[20] page;
        size_t rotation;
    }
    auto context = new Context;
    foreach (i; 0 .. context.values.length)
    {
        context.values[i].id.low = i + 1;
        context.values[i].score.total = cast(long)((i * 37) % 101);
        context.values[i].recencyKey = cast(long)((i * 11) % 17);
    }
    benchIter({
        context.rotation = (context.rotation + 1) % context.values.length;
        assert(!context.top.reset(0, context.page.length).hasError);
        foreach (i; 0 .. context.values.length)
        {
            const at = (i + context.rotation) % context.values.length;
            assert(!context.top.offer(blackBox(context.values[at])).hasError);
        }
        auto count = context.top.page(context.page);
        assert(count.hasValue && count.value == context.page.length);
        blackBox(context.page[0].score.total);
    }, ["profile": "n/a", "tier": "ranked-topK",
        "construction": "generation-reset-included",
        "corpus": "64-ranked-results"]);
}
