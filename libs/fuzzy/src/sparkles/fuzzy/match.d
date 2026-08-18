/** Exact bounded-deletion admission, canonical positions, and bounded scoring. */
module sparkles.fuzzy.match;

import sparkles.base.text.analysis : AnalysisCase, AnalysisError,
    AnalysisOptions, AnalysisWorkspace, TextUnit, analyzeText;

import sparkles.fuzzy.common : AnalysisProfileKind, CandidateView,
    DefaultFuzzyCaps, FuzzyErrorCode, FuzzyExpected, FuzzyLimits, TextRange,
    fuzzyErr, fuzzyOk, isPathSeparator, typoBudget, validateCandidate,
    validateLimits;
import sparkles.fuzzy.query : QueryParseOptions, QueryStorage, parseQuery;

import sparkles.test_runner.attributes : benchmark;

/// Admission/ranking tier selected for one candidate.
enum MatchKind : ubyte
{
    rejected,
    matched,
    matchedFallback,
    noFuzzyTerms,
}

/// Needle-deletion policy. Zero disables typo tolerance explicitly.
struct MatchConfig
{
    uint maxTypos = DefaultFuzzyCaps.maxTypos;
}

/// Validated affine local-alignment constants.
struct Scoring
{
    uint matchReward = 12;
    uint mismatchPenalty = 6;
    uint gapOpen = 5;
    uint gapExtend = 1;
    uint prefixBonus = 12;
    uint delimiterBonus = 4;
    uint camelBonus = 8;
    uint matchingCaseBonus = 4;
    uint exactBonus = 8;
}

/// Validate score arithmetic before processing candidates.
FuzzyExpected!Scoring validateScoring(Caps = DefaultFuzzyCaps)(
    Scoring scoring = Scoring.init, FuzzyLimits limits = FuzzyLimits.init)
    @safe pure nothrow @nogc
{
    auto checkedLimits = validateLimits!Caps(limits);
    if (checkedLimits.hasError)
        return fuzzyErr!Scoring(checkedLimits.error.code);
    if (scoring.matchReward == 0 || scoring.gapOpen == 0
        || scoring.gapExtend == 0)
        return fuzzyErr!Scoring(FuzzyErrorCode.invalidConfiguration);
    const perUnit = cast(ulong) scoring.matchReward + scoring.prefixBonus
        + scoring.delimiterBonus + scoring.camelBonus
        + scoring.matchingCaseBonus + scoring.exactBonus;
    if (perUnit > uint.max
        || perUnit * checkedLimits.value.maxQueryUnits > uint.max)
        return fuzzyErr!Scoring(FuzzyErrorCode.arithmeticOverflow);
    return fuzzyOk(scoring);
}

/// Complete match summary. Byte offsets always refer to the borrowed path.
struct MatchOutcome
{
    MatchKind kind;
    uint score;
    size_t firstByte;
    size_t endByte;
    size_t typos;
    size_t analyzedUnits;
    size_t effectiveParts;
    size_t droppedParts;
    bool allInFilename;
    bool exactFilename;
    bool queryContainsSeparator;

    bool admitted() const @safe pure nothrow @nogc
        => kind != MatchKind.rejected;
}

private struct PartSpan
{
    size_t start;
    size_t length;
}

private enum TraceAction : ubyte
{
    skip,
    matched,
}

private struct TraceCell
{
    uint prefix;
    size_t previousBudget;
    TraceAction action;
}

/**
Fixed scratch for one match call.

The trace contains one predecessor per candidate/budget cursor, not a score or
match matrix. Score quality uses three rolling rows bounded by `maxDpUnits`.
*/
struct MatcherWorkspace(Caps = DefaultFuzzyCaps)
{
    private AnalysisWorkspace!(Caps.maxQueryUnits,
        Caps.maxNormalizationSegment) queryAnalysis;
    private AnalysisWorkspace!(Caps.maxCandidateUnits,
        Caps.maxNormalizationSegment) candidateAnalysis;
    private char[Caps.maxQueryBytes] decodedQuery = void;
    private TextUnit[Caps.maxQueryUnits] queryUnits = void;
    private PartSpan[Caps.maxFuzzyParts] parts = void;
    private size_t queryUnitCount;
    private size_t partCount;

    private uint[Caps.maxTypos + 1] previousPrefix = void;
    private uint[Caps.maxTypos + 1] preparedPrefix = void;
    private uint[Caps.maxTypos + 1] currentPrefix = void;
    private size_t[Caps.maxTypos + 1] preparedOrigin = void;
    private bool[Caps.maxTypos + 1] previousValid = void;
    private bool[Caps.maxTypos + 1] preparedValid = void;
    private bool[Caps.maxTypos + 1] currentValid = void;
    private TraceCell[(Caps.maxCandidateUnits + 1)
        * (Caps.maxTypos + 1)] trace = void;

    private uint[Caps.maxQueryUnits] witnessCandidate = void;
    private uint[Caps.maxQueryUnits] witnessQuery = void;
    private size_t witnessCount;

    private uint[Caps.maxDpUnits + 1] scorePrevious = void;
    private uint[Caps.maxDpUnits + 1] scoreCurrent = void;
    private uint[Caps.maxDpUnits + 1] scoreVertical = void;

    private TextRange[Caps.maxQueryUnits] ranges = void;
    private size_t rangeCount;

    // The prepared-query cache: the raw fuzzy-part texts (content, not
    // addresses — a reparsed query can reuse the same storage) plus the
    // limits the preparation depended on. While the key matches, the
    // decoded/analyzed query state above is reused instead of re-running
    // the smart-case probe and Unicode analysis once per candidate. The
    // `= void` payloads are guarded by `queryPrepared_`, which is
    // deliberately default-initialized.
    private char[Caps.maxQueryBytes] cachedQueryRaw = void;
    private size_t[Caps.maxFuzzyParts] cachedRawLength = void;
    private size_t[Caps.maxFuzzyParts] cachedSkipFront = void;
    private size_t[Caps.maxFuzzyParts] cachedSkipBack = void;
    private size_t cachedPartCount;
    private size_t cachedLimitFuzzyParts;
    private size_t cachedLimitQueryUnits;
    private AnalysisOptions candidateOptions;
    private bool queryPrepared_;

    /// Canonical merged ranges from the last successful `match` call.
    const(TextRange)[] lastRanges() const return scope
        @safe pure nothrow @nogc
        => matcherRanges(this);
}

// One exclusive workspace per worker stays below the declared one-MiB budget.
static assert(MatcherWorkspace!().sizeof <= 1 * 1_024 * 1_024);

private const(TextRange)[] matcherRanges(Caps)(
    return scope ref const MatcherWorkspace!Caps workspace)
    @trusted pure nothrow @nogc
    => workspace.ranges[0 .. workspace.rangeCount];

/**
Analyze, admit, and score one candidate.

Complexity is `O(candidateUnits * (maxTypos + 1))` for admission plus
`O(queryUnits * maxDpUnits)` scoring per effective part. All storage is in
`workspace`; the query and candidate remain borrowed.
*/
FuzzyExpected!MatchOutcome match(Caps = DefaultFuzzyCaps)(
    in QueryStorage!Caps query, in CandidateView candidate,
    MatchConfig config, Scoring scoring, FuzzyLimits limits,
    ref MatcherWorkspace!Caps workspace) @safe pure nothrow @nogc
{
    auto checkedLimits = validateLimits!Caps(limits);
    if (checkedLimits.hasError)
        return fuzzyErr!MatchOutcome(checkedLimits.error.code);
    auto checkedScoring = validateScoring!Caps(scoring, checkedLimits.value);
    if (checkedScoring.hasError)
        return fuzzyErr!MatchOutcome(checkedScoring.error.code);
    if (config.maxTypos > Caps.maxTypos)
        return fuzzyErr!MatchOutcome(FuzzyErrorCode.invalidConfiguration,
            config.maxTypos);
    auto checkedCandidate = validateCandidate!Caps(candidate,
        checkedLimits.value);
    if (checkedCandidate.hasError)
        return fuzzyErr!MatchOutcome(checkedCandidate.error.code,
            checkedCandidate.error.offset, checkedCandidate.error.context);

    auto prepared = prepareText(query, candidate, checkedLimits.value,
        workspace);
    if (prepared.hasError)
        return fuzzyErr!MatchOutcome(prepared.error.code,
            prepared.error.offset, prepared.error.context);

    MatchOutcome outcome;
    outcome.kind = MatchKind.noFuzzyTerms;
    outcome.firstByte = size_t.max;
    outcome.effectiveParts = workspace.partCount;
    outcome.analyzedUnits = workspace.candidateAnalysis.output.length;
    outcome.droppedParts = query.fuzzyParts.length - workspace.partCount;
    outcome.allInFilename = workspace.partCount != 0;
    outcome.queryContainsSeparator = queryHasSeparator(workspace);
    workspace.rangeCount = 0;

    if (workspace.partCount == 0)
    {
        outcome.firstByte = 0;
        return fuzzyOk(outcome);
    }

    ulong scoreSum;
    bool usedFallback;
    foreach (partIndex; 0 .. workspace.partCount)
    {
        const part = workspace.parts[partIndex];
        const needle = workspace.queryUnits[part.start
            .. part.start + part.length];
        const budget = typoBudget(needle.length, config.maxTypos);
        auto witnessed = buildWitness(needle,
            workspace.candidateAnalysis.output, budget, workspace);
        if (!witnessed)
        {
            outcome.kind = MatchKind.rejected;
            outcome.score = 0;
            outcome.firstByte = 0;
            outcome.endByte = 0;
            workspace.rangeCount = 0;
            return fuzzyOk(outcome);
        }
        outcome.typos += needle.length - workspace.witnessCount;

        uint partScore;
        if (workspace.candidateAnalysis.output.length
            <= checkedLimits.value.maxDpUnits)
        {
            partScore = scoreAligned(needle,
                workspace.candidateAnalysis.output, checkedScoring.value,
                workspace);
        }
        else
        {
            usedFallback = true;
            partScore = scoreWitness(needle,
                workspace.candidateAnalysis.output, checkedScoring.value,
                workspace);
        }
        scoreSum += partScore;
        collectWitness(candidate.filenameOffset, outcome, workspace);
    }

    sortAndMergeRanges(workspace);
    outcome.score = cast(uint)(scoreSum / workspace.partCount);
    if (outcome.score == 0)
        outcome.score = 1;
    outcome.kind = usedFallback ? MatchKind.matchedFallback
        : MatchKind.matched;
    outcome.exactFilename = exactFilename(workspace, candidate.filenameOffset);
    if (outcome.firstByte == size_t.max)
        outcome.firstByte = 0;
    return fuzzyOk(outcome);
}

/// Convenience overload using the default bounded policies.
FuzzyExpected!MatchOutcome match(Caps = DefaultFuzzyCaps)(
    in QueryStorage!Caps query, in CandidateView candidate,
    ref MatcherWorkspace!Caps workspace) @safe pure nothrow @nogc
{
    return match(query, candidate, MatchConfig.init, Scoring.init,
        FuzzyLimits.init, workspace);
}

/**
Rerun the authoritative witness and copy all merged highlight ranges.

On `outputFull`, `error.offset` is the required range count and no partial
success is reported.
*/
FuzzyExpected!size_t positions(Caps = DefaultFuzzyCaps, size_t N)(
    in QueryStorage!Caps query, in CandidateView candidate,
    MatchConfig config, FuzzyLimits limits,
    ref MatcherWorkspace!Caps workspace, ref TextRange[N] output)
    @safe pure nothrow @nogc
{
    auto result = match(query, candidate, config, Scoring.init, limits,
        workspace);
    if (result.hasError)
        return fuzzyErr!size_t(result.error.code, result.error.offset,
            result.error.context);
    if (!result.value.admitted)
        return fuzzyOk(size_t(0));
    if (workspace.rangeCount > N
        || workspace.rangeCount > limits.maxPositionRanges)
        return fuzzyErr!size_t(FuzzyErrorCode.outputFull,
            workspace.rangeCount);
    foreach (i; 0 .. workspace.rangeCount)
        output[i] = workspace.ranges[i];
    return fuzzyOk(workspace.rangeCount);
}

private FuzzyExpected!void prepareText(Caps)(in QueryStorage!Caps query,
    in CandidateView candidate, in FuzzyLimits limits,
    ref MatcherWorkspace!Caps workspace) @safe pure nothrow @nogc
{
    // The query is immutable across a whole generation of candidates, so its
    // decode + smart-case probe + Unicode analysis run once per query, not
    // once per match call.
    if (!queryPreparationReusable(query, limits, workspace))
    {
        auto prepared = prepareQuery(query, limits, workspace);
        if (prepared.hasError)
            return prepared;
    }

    // The stored options never carry borrowed slices; the general-language
    // stopword lexicon is re-attached from the query per call.
    AnalysisOptions options = workspace.candidateOptions;
    if (query.profile.kind == AnalysisProfileKind.generalLanguage)
        options.stopwords = query.profile.stopwords;
    auto candidateResult = analyzeText(candidate.path, options,
        workspace.candidateAnalysis);
    if (!candidateResult.succeeded)
        return analysisFailure(false, candidateResult.error,
            candidateResult.sourceOffset);
    if (workspace.candidateAnalysis.output.length > limits.maxCandidateUnits)
        return fuzzyErr!void(FuzzyErrorCode.candidateTooComplex,
            workspace.candidateAnalysis.output.length);
    return fuzzyOk();
}

private FuzzyExpected!void prepareQuery(Caps)(in QueryStorage!Caps query,
    in FuzzyLimits limits, ref MatcherWorkspace!Caps workspace)
    @safe pure nothrow @nogc
{
    workspace.queryPrepared_ = false;
    workspace.queryUnitCount = 0;
    workspace.partCount = 0;

    bool sensitive;
    if (query.profile.kind == AnalysisProfileKind.codePath)
    {
        foreach (text; query.fuzzyParts)
        {
            auto decoded = text.decodeInto(workspace.decodedQuery);
            if (decoded.hasError)
                return fuzzyErr!void(decoded.error.code, decoded.error.offset);
            auto probe = analyzeText(workspace.decodedQuery[0 .. decoded.value],
                AnalysisOptions.codePath(AnalysisCase.sensitive),
                workspace.queryAnalysis);
            if (!probe.succeeded)
                return analysisFailure(true, probe.error, probe.sourceOffset);
            sensitive |= probe.containsUppercase;
        }
    }

    AnalysisOptions options;
    final switch (query.profile.kind)
    {
    case AnalysisProfileKind.codePath:
        options = AnalysisOptions.codePath(sensitive
            ? AnalysisCase.sensitive : AnalysisCase.simpleFold);
        break;
    case AnalysisProfileKind.generalLanguage:
        options = AnalysisOptions.generalLanguage(query.profile.stopwords);
        break;
    }

    foreach (text; query.fuzzyParts)
    {
        auto decoded = text.decodeInto(workspace.decodedQuery);
        if (decoded.hasError)
            return fuzzyErr!void(decoded.error.code, decoded.error.offset);
        auto analyzed = analyzeText(workspace.decodedQuery[0 .. decoded.value],
            options, workspace.queryAnalysis);
        if (!analyzed.succeeded)
            return analysisFailure(true, analyzed.error, analyzed.sourceOffset);
        if (workspace.queryAnalysis.output.length < 2)
            continue;
        if (workspace.partCount == limits.maxFuzzyParts
            || workspace.queryUnitCount + workspace.queryAnalysis.output.length
                > limits.maxQueryUnits)
            return fuzzyErr!void(FuzzyErrorCode.queryTooComplex,
                workspace.queryUnitCount);
        const start = workspace.queryUnitCount;
        foreach (unit; workspace.queryAnalysis.output)
            workspace.queryUnits[workspace.queryUnitCount++] = unit;
        workspace.parts[workspace.partCount++] = PartSpan(start,
            workspace.queryAnalysis.output.length);
    }

    // Store a slice-free copy of the resolved options (`prepareText`
    // re-attaches the borrowed stopword lexicon). Only the code-path profile
    // is remembered by the cache: general-language options depend on lexicon
    // contents this cache cannot cheaply fingerprint, so that profile
    // re-prepares per call.
    final switch (query.profile.kind)
    {
    case AnalysisProfileKind.codePath:
        workspace.candidateOptions = AnalysisOptions.codePath(sensitive
            ? AnalysisCase.sensitive : AnalysisCase.simpleFold);
        rememberPreparedQuery(query, limits, workspace);
        break;
    case AnalysisProfileKind.generalLanguage:
        workspace.candidateOptions = AnalysisOptions.generalLanguage();
        break;
    }
    return fuzzyOk();
}

private bool queryPreparationReusable(Caps)(in QueryStorage!Caps query,
    in FuzzyLimits limits, ref const MatcherWorkspace!Caps workspace)
    @safe pure nothrow @nogc
{
    if (!workspace.queryPrepared_
        || query.profile.kind != AnalysisProfileKind.codePath
        || query.fuzzyParts.length != workspace.cachedPartCount
        || limits.maxFuzzyParts != workspace.cachedLimitFuzzyParts
        || limits.maxQueryUnits != workspace.cachedLimitQueryUnits)
        return false;
    size_t at;
    foreach (i, text; query.fuzzyParts)
    {
        // Compare content, never addresses: a keystroke's reparse typically
        // reuses the same query storage, so identical spans can hold a
        // different query.
        if (text.raw.length != workspace.cachedRawLength[i]
            || text.skipFront != workspace.cachedSkipFront[i]
            || text.skipBack != workspace.cachedSkipBack[i]
            || text.raw != workspace.cachedQueryRaw[at .. at + text.raw.length])
            return false;
        at += text.raw.length;
    }
    return true;
}

private void rememberPreparedQuery(Caps)(in QueryStorage!Caps query,
    in FuzzyLimits limits, ref MatcherWorkspace!Caps workspace)
    @safe pure nothrow @nogc
{
    size_t at;
    foreach (i, text; query.fuzzyParts)
    {
        if (text.raw.length > workspace.cachedQueryRaw.length - at)
            return; // does not fit; leave the cache invalid
        workspace.cachedRawLength[i] = text.raw.length;
        workspace.cachedSkipFront[i] = text.skipFront;
        workspace.cachedSkipBack[i] = text.skipBack;
        workspace.cachedQueryRaw[at .. at + text.raw.length] = text.raw;
        at += text.raw.length;
    }
    workspace.cachedPartCount = query.fuzzyParts.length;
    workspace.cachedLimitFuzzyParts = limits.maxFuzzyParts;
    workspace.cachedLimitQueryUnits = limits.maxQueryUnits;
    workspace.queryPrepared_ = true;
}

private FuzzyExpected!void analysisFailure(bool query, AnalysisError error,
    size_t offset) @safe pure nothrow @nogc
{
    final switch (error)
    {
    case AnalysisError.none:
        return fuzzyOk();
    case AnalysisError.invalidOptions:
        return fuzzyErr!void(FuzzyErrorCode.invalidConfiguration, offset);
    case AnalysisError.sourceTooLong:
        return fuzzyErr!void(query ? FuzzyErrorCode.queryTooComplex
            : FuzzyErrorCode.candidateTooLong, offset);
    case AnalysisError.outputFull:
        return fuzzyErr!void(query ? FuzzyErrorCode.queryTooComplex
            : FuzzyErrorCode.candidateTooComplex, offset);
    case AnalysisError.segmentTooLong:
        return fuzzyErr!void(FuzzyErrorCode.normalizationSegmentTooLong,
            offset);
    }
}

private bool buildWitness(Caps)(scope const(TextUnit)[] needle,
    scope const(TextUnit)[] candidate, uint budget,
    ref MatcherWorkspace!Caps workspace) @safe pure nothrow @nogc
{
    const stride = Caps.maxTypos + 1;
    foreach (d; 0 .. stride)
    {
        workspace.previousPrefix[d] = 0;
        workspace.previousValid[d] = false;
    }
    workspace.previousValid[0] = true;

    foreach (candidateIndex, candidateUnit; candidate)
    {
        foreach (d; 0 .. budget + 1)
        {
            workspace.preparedValid[d] = workspace.previousValid[d];
            workspace.preparedPrefix[d] = workspace.previousPrefix[d];
            workspace.preparedOrigin[d] = d;
            if (d != 0 && workspace.preparedValid[d - 1]
                && workspace.preparedPrefix[d - 1] < needle.length)
            {
                const advanced = workspace.preparedPrefix[d - 1] + 1;
                if (!workspace.preparedValid[d]
                    || advanced > workspace.preparedPrefix[d])
                {
                    workspace.preparedValid[d] = true;
                    workspace.preparedPrefix[d] = advanced;
                    workspace.preparedOrigin[d]
                        = workspace.preparedOrigin[d - 1];
                }
            }

            workspace.currentValid[d] = workspace.preparedValid[d];
            workspace.currentPrefix[d] = workspace.preparedPrefix[d];
            TraceAction action = TraceAction.skip;
            if (workspace.preparedValid[d]
                && workspace.preparedPrefix[d] < needle.length
                && needle[workspace.preparedPrefix[d]].value
                    == candidateUnit.value)
            {
                ++workspace.currentPrefix[d];
                action = TraceAction.matched;
            }
            workspace.trace[(candidateIndex + 1) * stride + d] = TraceCell(
                workspace.currentPrefix[d], workspace.preparedOrigin[d],
                action);
        }
        foreach (d; 0 .. budget + 1)
        {
            workspace.previousValid[d] = workspace.currentValid[d];
            workspace.previousPrefix[d] = workspace.currentPrefix[d];
        }
    }

    // Close trailing needle deletions without needing another trace row.
    foreach (d; 0 .. budget + 1)
    {
        workspace.preparedValid[d] = workspace.previousValid[d];
        workspace.preparedPrefix[d] = workspace.previousPrefix[d];
        workspace.preparedOrigin[d] = d;
        if (d != 0 && workspace.preparedValid[d - 1]
            && workspace.preparedPrefix[d - 1] < needle.length)
        {
            const advanced = workspace.preparedPrefix[d - 1] + 1;
            if (!workspace.preparedValid[d]
                || advanced > workspace.preparedPrefix[d])
            {
                workspace.preparedValid[d] = true;
                workspace.preparedPrefix[d] = advanced;
                workspace.preparedOrigin[d] = workspace.preparedOrigin[d - 1];
            }
        }
    }

    uint acceptedBudget = uint.max;
    size_t traceBudget;
    foreach (d; 0 .. budget + 1)
    {
        if (workspace.preparedValid[d]
            && workspace.preparedPrefix[d] >= needle.length)
        {
            acceptedBudget = cast(uint) d;
            traceBudget = workspace.preparedOrigin[d];
            break;
        }
    }
    if (acceptedBudget == uint.max)
        return false;

    workspace.witnessCount = 0;
    size_t row = candidate.length;
    auto d = traceBudget;
    while (row != 0)
    {
        const cell = workspace.trace[row * stride + d];
        if (cell.action == TraceAction.matched)
        {
            workspace.witnessCandidate[workspace.witnessCount]
                = cast(uint)(row - 1);
            workspace.witnessQuery[workspace.witnessCount]
                = cell.prefix - 1;
            ++workspace.witnessCount;
        }
        d = cell.previousBudget;
        --row;
    }
    foreach (i; 0 .. workspace.witnessCount / 2)
    {
        const opposite = workspace.witnessCount - i - 1;
        auto candidatePosition = workspace.witnessCandidate[i];
        workspace.witnessCandidate[i] = workspace.witnessCandidate[opposite];
        workspace.witnessCandidate[opposite] = candidatePosition;
        auto queryPosition = workspace.witnessQuery[i];
        workspace.witnessQuery[i] = workspace.witnessQuery[opposite];
        workspace.witnessQuery[opposite] = queryPosition;
    }
    return true;
}

private uint scoreAligned(Caps)(scope const(TextUnit)[] needle,
    scope const(TextUnit)[] candidate, in Scoring scoring,
    ref MatcherWorkspace!Caps workspace) @safe pure nothrow @nogc
{
    const first = workspace.witnessCandidate[0];
    const pastLast = workspace.witnessCandidate[workspace.witnessCount - 1] + 1;
    const window = candidate[first .. pastLast];
    foreach (j; 0 .. window.length + 1)
    {
        workspace.scorePrevious[j] = 0;
        workspace.scoreVertical[j] = 0;
    }

    uint best;
    foreach (queryIndex, queryUnit; needle)
    {
        workspace.scoreCurrent[0] = 0;
        long horizontal = long.min / 4;
        foreach (windowIndex, candidateUnit; window)
        {
            const j = windowIndex + 1;
            long diagonal = workspace.scorePrevious[j - 1];
            if (queryUnit.value == candidateUnit.value)
                diagonal += scoring.matchReward
                    + unitBonuses(queryUnit, candidate, first + windowIndex,
                        scoring);
            else
                diagonal -= scoring.mismatchPenalty;

            const vertical = maxLong(
                cast(long) workspace.scorePrevious[j] - scoring.gapOpen,
                cast(long) workspace.scoreVertical[j] - scoring.gapExtend);
            workspace.scoreVertical[j] = vertical > 0
                ? cast(uint) vertical : 0;
            horizontal = maxLong(
                cast(long) workspace.scoreCurrent[j - 1] - scoring.gapOpen,
                horizontal - scoring.gapExtend);
            auto value = maxLong(0, maxLong(diagonal,
                maxLong(vertical, horizontal)));
            workspace.scoreCurrent[j] = cast(uint) value;
            if (queryIndex + 1 == needle.length
                && workspace.scoreCurrent[j] > best)
                best = workspace.scoreCurrent[j];
        }
        foreach (j; 0 .. window.length + 1)
            workspace.scorePrevious[j] = workspace.scoreCurrent[j];
    }
    if (sequencesEqual(needle, window))
        best += scoring.exactBonus;
    return best == 0 ? 1 : best;
}

private uint scoreWitness(Caps)(scope const(TextUnit)[] needle,
    scope const(TextUnit)[] candidate, in Scoring scoring,
    ref MatcherWorkspace!Caps workspace) @safe pure nothrow @nogc
{
    long result;
    foreach (i; 0 .. workspace.witnessCount)
    {
        const candidateIndex = workspace.witnessCandidate[i];
        const queryIndex = workspace.witnessQuery[i];
        result += scoring.matchReward + unitBonuses(needle[queryIndex],
            candidate, candidateIndex, scoring);
        if (i != 0)
        {
            const candidateGap = candidateIndex
                - workspace.witnessCandidate[i - 1] - 1;
            const queryGap = queryIndex - workspace.witnessQuery[i - 1] - 1;
            result -= gapCost(candidateGap, scoring);
            result -= gapCost(queryGap, scoring);
        }
    }
    const first = workspace.witnessCandidate[0];
    const pastLast = workspace.witnessCandidate[workspace.witnessCount - 1] + 1;
    if (sequencesEqual(needle, candidate[first .. pastLast]))
        result += scoring.exactBonus;
    return result > 0 ? cast(uint) result : 1;
}

private uint unitBonuses(in TextUnit query, scope const(TextUnit)[] candidate,
    size_t at, in Scoring scoring) @safe pure nothrow @nogc
{
    uint result;
    if (at == 0)
        result += scoring.prefixBonus;
    else
    {
        const previous = candidate[at - 1];
        if (isDelimiter(previous.value))
            result += scoring.delimiterBonus;
        if (candidate[at].sourceWasUppercase
            && !previous.sourceWasUppercase)
            result += scoring.camelBonus;
    }
    if (query.sourceWasUppercase == candidate[at].sourceWasUppercase)
        result += scoring.matchingCaseBonus;
    return result;
}

private bool isDelimiter(uint value) @safe pure nothrow @nogc
    => value == '/' || value == '\\' || value == '_' || value == '-'
        || value == '.' || value == ' ' || value == ':';

private long gapCost(uint length, in Scoring scoring)
    @safe pure nothrow @nogc
{
    return length == 0 ? 0 : cast(long) scoring.gapOpen
        + cast(long)(length - 1) * scoring.gapExtend;
}

private long maxLong(long left, long right) @safe pure nothrow @nogc
    => left > right ? left : right;

private bool sequencesEqual(scope const(TextUnit)[] left,
    scope const(TextUnit)[] right) @safe pure nothrow @nogc
{
    if (left.length != right.length)
        return false;
    foreach (i; 0 .. left.length)
        if (left[i].value != right[i].value)
            return false;
    return true;
}

private void collectWitness(Caps)(size_t filenameOffset,
    ref MatchOutcome outcome, ref MatcherWorkspace!Caps workspace)
    @safe pure nothrow @nogc
{
    foreach (i; 0 .. workspace.witnessCount)
    {
        const unit = workspace.candidateAnalysis.output[
            workspace.witnessCandidate[i]];
        if (unit.sourceStart < outcome.firstByte)
            outcome.firstByte = unit.sourceStart;
        if (unit.sourceEnd > outcome.endByte)
            outcome.endByte = unit.sourceEnd;
        if (unit.sourceStart < filenameOffset)
            outcome.allInFilename = false;
        workspace.ranges[workspace.rangeCount++] = TextRange(
            unit.sourceStart, unit.sourceEnd);
    }
}

private void sortAndMergeRanges(Caps)(ref MatcherWorkspace!Caps workspace)
    @safe pure nothrow @nogc
{
    foreach (i; 1 .. workspace.rangeCount)
    {
        const value = workspace.ranges[i];
        size_t at = i;
        while (at != 0 && (workspace.ranges[at - 1].start > value.start
                || (workspace.ranges[at - 1].start == value.start
                    && workspace.ranges[at - 1].end > value.end)))
        {
            workspace.ranges[at] = workspace.ranges[at - 1];
            --at;
        }
        workspace.ranges[at] = value;
    }
    size_t write;
    foreach (read; 0 .. workspace.rangeCount)
    {
        const value = workspace.ranges[read];
        if (write != 0 && value.start <= workspace.ranges[write - 1].end)
        {
            if (value.end > workspace.ranges[write - 1].end)
                workspace.ranges[write - 1].end = value.end;
        }
        else
            workspace.ranges[write++] = value;
    }
    workspace.rangeCount = write;
}

private bool exactFilename(Caps)(ref MatcherWorkspace!Caps workspace,
    size_t filenameOffset) @safe pure nothrow @nogc
{
    if (workspace.partCount != 1)
        return false;
    const part = workspace.parts[0];
    size_t first;
    const candidate = workspace.candidateAnalysis.output;
    while (first < candidate.length
        && candidate[first].sourceStart < filenameOffset)
        ++first;
    return sequencesEqual(workspace.queryUnits[part.start
        .. part.start + part.length], candidate[first .. $]);
}

private bool queryHasSeparator(Caps)(ref MatcherWorkspace!Caps workspace)
    @safe pure nothrow @nogc
{
    foreach (unit; workspace.queryUnits[0 .. workspace.queryUnitCount])
        if (unit.value == '/' || unit.value == '\\')
            return true;
    return false;
}

@("fuzzy.match.exactAdmissionAndEndpointDeletion")
@safe pure nothrow @nogc
unittest
{
    auto query = parseQuery("abcd");
    assert(query.hasValue);
    CandidateView candidate;
    candidate.path = "xxabdyy";
    candidate.filenameOffset = 0;
    MatcherWorkspace!() workspace;
    auto result = match(query.value, candidate, workspace);
    assert(result.hasValue);
    assert(result.value.kind == MatchKind.matched);
    assert(result.value.typos == 1);
    assert(result.value.firstByte == 2);
    assert(result.value.endByte == 5);

    candidate.path = "xxabyy";
    result = match(query.value, candidate, workspace);
    assert(result.hasValue && result.value.kind == MatchKind.rejected);

    candidate.path = "abxd";
    result = match(query.value, candidate, workspace);
    assert(result.hasValue && result.value.admitted && result.value.typos == 1);
    candidate.path = "abdc";
    result = match(query.value, candidate, workspace);
    assert(result.hasValue && result.value.admitted && result.value.typos == 1);
}

@("fuzzy.match.smartCaseUnicodeAndPositions")
@safe pure nothrow @nogc
unittest
{
    auto insensitive = parseQuery("äff");
    auto sensitive = parseQuery("Äff");
    CandidateView candidate;
    candidate.path = "src/Äffin.d";
    candidate.filenameOffset = 4;
    MatcherWorkspace!() workspace;
    assert(match(insensitive.value, candidate, workspace).value.admitted);
    candidate.path = "src/äffin.d";
    auto caseResult = match(sensitive.value, candidate, MatchConfig(0),
        Scoring.init, FuzzyLimits.init, workspace);
    assert(caseResult.hasValue && !caseResult.value.admitted);

    candidate.path = "src/A\u0308ffin.d";
    TextRange[8] ranges;
    auto found = positions(insensitive.value, candidate, MatchConfig.init,
        FuzzyLimits.init, workspace, ranges);
    assert(found.hasValue && found.value != 0);
    assert(ranges[0].start == 4 && ranges[0].end == 9);
}

@("fuzzy.match.camelSnakeAndExactGoldens")
@safe pure nothrow @nogc
unittest
{
    auto query = parseQuery("fb");
    assert(query.hasValue);
    MatcherWorkspace!() workspace;
    CandidateView candidate;

    candidate.path = "foobar";
    const plain = match(query.value, candidate, MatchConfig(0),
        Scoring.init, FuzzyLimits.init, workspace).value.score;
    candidate.path = "foo_bar";
    const snake = match(query.value, candidate, MatchConfig(0),
        Scoring.init, FuzzyLimits.init, workspace).value.score;
    candidate.path = "fooBar";
    const camel = match(query.value, candidate, MatchConfig(0),
        Scoring.init, FuzzyLimits.init, workspace).value.score;
    candidate.path = "fb";
    const exact = match(query.value, candidate, MatchConfig(0),
        Scoring.init, FuzzyLimits.init, workspace).value.score;

    assert(plain == 38);
    assert(snake == 41);
    assert(camel == 42);
    assert(exact == 52);
}

@("fuzzy.match.queryPreparationCacheTracksContentNotAddresses")
@safe pure nothrow @nogc
unittest
{
    CandidateView candidate;
    candidate.path = "src/Abc.d";
    candidate.filenameOffset = 4;

    // Reparsing into the same storage reuses the same span addresses with
    // different content — the cache must key on content.
    MatcherWorkspace!() shared_;
    char[3] prompt = "abc";
    auto query = parseQuery(prompt[]);
    const first = match(query.value, candidate, shared_).value;
    prompt = "Abc"; // smart-case flips to sensitive
    query = parseQuery(prompt[]);
    const second = match(query.value, candidate, shared_).value;
    prompt = "abc";
    query = parseQuery(prompt[]);
    const third = match(query.value, candidate, shared_).value;

    MatcherWorkspace!() freshLower;
    auto lower = parseQuery("abc");
    const expectedLower = match(lower.value, candidate, freshLower).value;
    MatcherWorkspace!() freshUpper;
    auto upper = parseQuery("Abc");
    const expectedUpper = match(upper.value, candidate, freshUpper).value;

    assert(first.kind == expectedLower.kind
        && first.score == expectedLower.score);
    assert(second.kind == expectedUpper.kind
        && second.score == expectedUpper.score);
    assert(third.kind == expectedLower.kind
        && third.score == expectedLower.score);
    // The insensitive and sensitive preparations must actually differ, or
    // the assertions above prove nothing.
    assert(expectedLower.score != expectedUpper.score
        || expectedLower.kind != expectedUpper.kind);
}

@("fuzzy.match.cursorDpMatchesExhaustiveLcsOracle")
@safe pure nothrow @nogc
unittest
{
    MatcherWorkspace!() workspace;
    TextUnit[5] needle = void;
    TextUnit[5] candidate = void;
    foreach (needleLength; 2 .. 6)
    foreach (candidateLength; 0 .. 6)
    foreach (needleBits; 0 .. 1 << needleLength)
    foreach (candidateBits; 0 .. 1 << candidateLength)
    {
        foreach (i; 0 .. needleLength)
            needle[i] = TextUnit('a' + ((needleBits >> i) & 1),
                cast(uint) i, cast(uint) i + 1);
        foreach (i; 0 .. candidateLength)
            candidate[i] = TextUnit('a' + ((candidateBits >> i) & 1),
                cast(uint) i, cast(uint) i + 1);
        const lcs = lcsLength(needle[0 .. needleLength],
            candidate[0 .. candidateLength]);
        foreach (budget; 0 .. 3)
        {
            const admitted = buildWitness(needle[0 .. needleLength],
                candidate[0 .. candidateLength], cast(uint) budget,
                workspace);
            assert(admitted == (lcs + budget >= needleLength));
            if (!admitted)
                continue;
            assert(workspace.witnessCount == needleLength
                - (needleLength - lcs < budget
                    ? needleLength - lcs : budget));
            foreach (i; 0 .. workspace.witnessCount)
            {
                assert(needle[workspace.witnessQuery[i]].value
                    == candidate[workspace.witnessCandidate[i]].value);
                if (i != 0)
                {
                    assert(workspace.witnessQuery[i]
                        > workspace.witnessQuery[i - 1]);
                    assert(workspace.witnessCandidate[i]
                        > workspace.witnessCandidate[i - 1]);
                }
            }
        }
    }
}

@("fuzzy.match.witnessMatchesCanonicalExhaustiveOracle")
@safe pure nothrow @nogc
unittest
{
    MatcherWorkspace!() workspace;
    TextUnit[4] needle = void;
    TextUnit[4] candidate = void;
    uint[4] expected = void;
    foreach (needleLength; 2 .. 5)
    foreach (candidateLength; 1 .. 5)
    foreach (needleBits; 0 .. 1 << needleLength)
    foreach (candidateBits; 0 .. 1 << candidateLength)
    foreach (budget; 0 .. (needleLength > 2 ? 3 : 2))
    {
        foreach (i; 0 .. needleLength)
            needle[i] = TextUnit('a' + ((needleBits >> i) & 1),
                cast(uint) i, cast(uint) i + 1);
        foreach (i; 0 .. candidateLength)
            candidate[i] = TextUnit('a' + ((candidateBits >> i) & 1),
                cast(uint) i, cast(uint) i + 1);
        const expectedCount = canonicalWitnessOracle(
            needle[0 .. needleLength], candidate[0 .. candidateLength],
            cast(uint) budget, expected);
        const admitted = buildWitness(needle[0 .. needleLength],
            candidate[0 .. candidateLength], cast(uint) budget, workspace);
        assert(admitted == (expectedCount != size_t.max));
        if (!admitted)
            continue;
        assert(workspace.witnessCount == expectedCount);
        foreach (i; 0 .. expectedCount)
            assert(workspace.witnessCandidate[i] == expected[i]);
    }
}

private size_t canonicalWitnessOracle(scope const(TextUnit)[] needle,
    scope const(TextUnit)[] candidate, uint budget, ref uint[4] best)
    @safe pure nothrow @nogc
{
    size_t bestCount;
    bool found;
    foreach (needleMask; 1U .. 1U << needle.length)
    {
        const count = bitCount(needleMask);
        if (needle.length - count > budget)
            continue;
        foreach (candidateMask; 1U .. 1U << candidate.length)
        {
            if (bitCount(candidateMask) != count)
                continue;
            uint[4] positions = void;
            size_t queryAt;
            size_t candidateAt;
            bool equal = true;
            foreach (i; 0 .. needle.length)
                if ((needleMask & (1U << i)) != 0)
                {
                    while ((candidateMask & (1U << candidateAt)) == 0)
                        ++candidateAt;
                    if (needle[i].value != candidate[candidateAt].value)
                        equal = false;
                    positions[queryAt++] = cast(uint) candidateAt++;
                }
            if (!equal)
                continue;
            if (!found || count > bestCount
                || (count == bestCount
                    && (positions[count - 1] < best[bestCount - 1]
                        || (positions[count - 1] == best[bestCount - 1]
                            && lexicographicallyBefore(
                                positions[0 .. count],
                                best[0 .. bestCount])))))
            {
                found = true;
                bestCount = count;
                best[0 .. count] = positions[0 .. count];
            }
        }
    }
    return found ? bestCount : size_t.max;
}

private size_t bitCount(uint value) @safe pure nothrow @nogc
{
    size_t result;
    while (value != 0)
    {
        result += value & 1;
        value >>= 1;
    }
    return result;
}

private bool lexicographicallyBefore(scope const(uint)[] left,
    scope const(uint)[] right) @safe pure nothrow @nogc
{
    foreach (i; 0 .. left.length)
    {
        if (left[i] != right[i])
            return left[i] < right[i];
    }
    return false;
}

private size_t lcsLength(scope const(TextUnit)[] left,
    scope const(TextUnit)[] right) @safe pure nothrow @nogc
{
    size_t[6][6] table;
    foreach (i; 1 .. left.length + 1)
    foreach (j; 1 .. right.length + 1)
        table[i][j] = left[i - 1].value == right[j - 1].value
            ? table[i - 1][j - 1] + 1
            : table[i - 1][j] > table[i][j - 1]
                ? table[i - 1][j] : table[i][j - 1];
    return table[left.length][right.length];
}

@("fuzzy.match.fallbackIsAdmitted")
@safe pure nothrow @nogc
unittest
{
    struct TinyCaps
    {
        enum size_t maxQueryUnits = 16;
        enum size_t maxQueryBytes = 32;
        enum size_t maxCandidateUnits = 32;
        enum size_t maxCandidateBytes = 32;
        enum size_t maxDpUnits = 4;
        enum size_t maxFuzzyParts = 4;
        enum size_t maxConstraints = 4;
        enum size_t maxGlobInstructions = 32;
        enum size_t maxGlobRanges = 16;
        enum size_t maxPositionRanges = 16;
        enum size_t maxNormalizationSegment = 16;
        enum size_t maxTypos = 2;
    }
    CandidateView candidate;
    candidate.path = "long-needle-path";
    MatcherWorkspace!TinyCaps workspace;
    FuzzyLimits limits;
    limits.maxQueryUnits = TinyCaps.maxQueryUnits;
    limits.maxQueryBytes = TinyCaps.maxQueryBytes;
    limits.maxCandidateUnits = TinyCaps.maxCandidateUnits;
    limits.maxCandidateBytes = TinyCaps.maxCandidateBytes;
    limits.maxDpUnits = TinyCaps.maxDpUnits;
    limits.maxFuzzyParts = TinyCaps.maxFuzzyParts;
    limits.maxConstraints = TinyCaps.maxConstraints;
    limits.maxGlobInstructions = TinyCaps.maxGlobInstructions;
    limits.maxGlobRanges = TinyCaps.maxGlobRanges;
    limits.maxPositionRanges = TinyCaps.maxPositionRanges;
    QueryParseOptions options;
    options.limits = limits;
    auto query = parseQuery!TinyCaps("needle", options);
    assert(query.hasValue);
    auto result = match(query.value, candidate, MatchConfig(2),
        Scoring.init, limits, workspace);
    assert(result.hasValue);
    assert(result.value.kind == MatchKind.matchedFallback);
    assert(result.value.score != 0);
}

@("fuzzy.match.bench.reusedWorkspace")
@benchmark @safe
unittest
{
    import sparkles.test_runner.bench : benchIter, blackBox;

    auto query = parseQuery("unicode table").value;
    class Context
    {
        bool upper;
        CandidateView candidate;
        MatcherWorkspace!() workspace;
    }
    auto context = new Context;
    context.candidate.path
        = "libs/base/src/sparkles/base/text/unicode_tables.d";
    context.candidate.filenameOffset = 33;
    auto warmup = match(query, context.candidate, context.workspace);
    assert(warmup.hasValue && warmup.value.kind == MatchKind.matched);
    benchIter({
        context.upper = !context.upper;
        context.candidate.path = context.upper
            ? "Libs/base/src/sparkles/base/text/unicode_tables.d"
            : "libs/base/src/sparkles/base/text/unicode_tables.d";
        auto result = match(blackBox(query), blackBox(context.candidate),
            context.workspace);
        assert(result.hasValue && result.value.kind == MatchKind.matched);
        blackBox(result.value.score);
    }, ["profile": "codePath", "tier": "score+positions",
        "construction": "excluded", "corpus": "single-path"]);
}
