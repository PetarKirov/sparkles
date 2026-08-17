/** Common bounded values shared by every `sparkles:fuzzy` module. */
module sparkles.fuzzy.common;

import expected : Expected, err, ok;

import sparkles.base.text.analysis : StopwordLexicon;
import sparkles.base.text.errors : NoGcHook;

/// Default compile-time capacities. Callers may provide a compatible type.
struct DefaultFuzzyCaps
{
    enum size_t maxQueryUnits = 256;
    enum size_t maxQueryBytes = 4_096;
    enum size_t maxCandidateUnits = 4_096;
    enum size_t maxCandidateBytes = 4_096;
    enum size_t maxDpUnits = 1_024;
    enum size_t maxFuzzyParts = 8;
    enum size_t maxConstraints = 16;
    enum size_t maxGlobInstructions = 512;
    enum size_t maxGlobRanges = 128;
    enum size_t maxPositionRanges = 256;
    enum size_t maxNormalizationSegment = 64;
    enum size_t maxTypos = 6;
}

/// Runtime limits validated against a compile-time capacity type.
struct FuzzyLimits
{
    size_t maxQueryUnits = DefaultFuzzyCaps.maxQueryUnits;
    size_t maxQueryBytes = DefaultFuzzyCaps.maxQueryBytes;
    size_t maxCandidateUnits = DefaultFuzzyCaps.maxCandidateUnits;
    size_t maxCandidateBytes = DefaultFuzzyCaps.maxCandidateBytes;
    size_t maxDpUnits = DefaultFuzzyCaps.maxDpUnits;
    size_t maxFuzzyParts = DefaultFuzzyCaps.maxFuzzyParts;
    size_t maxConstraints = DefaultFuzzyCaps.maxConstraints;
    size_t maxGlobInstructions = DefaultFuzzyCaps.maxGlobInstructions;
    size_t maxGlobRanges = DefaultFuzzyCaps.maxGlobRanges;
    size_t maxPositionRanges = DefaultFuzzyCaps.maxPositionRanges;
}

/// Machine-readable failure vocabulary across the library.
enum FuzzyErrorCode : ubyte
{
    none,
    invalidConfiguration,
    emptyValue,
    unexpectedCharacter,
    unexpectedEnd,
    invalidEscape,
    numericOverflow,
    unknownValue,
    ambiguousValue,
    malformedGlob,
    queryTooComplex,
    candidateTooLong,
    candidateTooComplex,
    normalizationSegmentTooLong,
    globTooComplex,
    outputFull,
    invalidCandidate,
    invalidCursor,
    arithmeticOverflow,
}

/// Structured error with a source byte offset or numeric detail.
struct FuzzyError
{
    FuzzyErrorCode code;
    size_t offset;
    string context;
}

/// Allocation-free expected result used by the package.
alias FuzzyExpected(T) = Expected!(T, FuzzyError, NoGcHook);

FuzzyExpected!T fuzzyOk(T)(T value) @safe pure nothrow @nogc
    => ok!(FuzzyError, NoGcHook)(value);

FuzzyExpected!void fuzzyOk() @safe pure nothrow @nogc
    => ok!(FuzzyError, NoGcHook)();

FuzzyExpected!T fuzzyErr(T)(FuzzyErrorCode code, size_t offset = 0,
    string context = null) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(FuzzyError(code, offset, context));

/// Validate runtime limits against a capacity type.
FuzzyExpected!FuzzyLimits validateLimits(Caps = DefaultFuzzyCaps)(
    FuzzyLimits limits = FuzzyLimits.init) @safe pure nothrow @nogc
{
    if (limits.maxQueryUnits == 0
        || limits.maxQueryUnits > Caps.maxQueryUnits
        || limits.maxQueryUnits > uint.max
        || limits.maxQueryBytes == 0
        || limits.maxQueryBytes > Caps.maxQueryBytes
        || limits.maxQueryBytes > uint.max
        || limits.maxCandidateUnits == 0
        || limits.maxCandidateUnits > Caps.maxCandidateUnits
        || limits.maxCandidateUnits > uint.max
        || limits.maxCandidateBytes == 0
        || limits.maxCandidateBytes > Caps.maxCandidateBytes
        || limits.maxCandidateBytes > uint.max
        || limits.maxDpUnits == 0
        || limits.maxDpUnits > Caps.maxDpUnits
        || limits.maxDpUnits > limits.maxCandidateUnits
        || limits.maxFuzzyParts == 0
        || limits.maxFuzzyParts > Caps.maxFuzzyParts
        || limits.maxConstraints == 0
        || limits.maxConstraints > Caps.maxConstraints
        || limits.maxGlobInstructions == 0
        || limits.maxGlobInstructions > Caps.maxGlobInstructions
        || limits.maxGlobRanges == 0
        || limits.maxGlobRanges > Caps.maxGlobRanges
        || limits.maxPositionRanges == 0
        || limits.maxPositionRanges > Caps.maxPositionRanges)
        return fuzzyErr!FuzzyLimits(FuzzyErrorCode.invalidConfiguration);
    return fuzzyOk(limits);
}

/**
The needle-deletion budget derived from one fuzzy part's length.

This is the single definition both admission (`match`, over analyzed units)
and survivor refinement (`refines`, over decoded ASCII bytes — equal to units
for the ASCII-only queries refinement accepts) must share: `refines`'s
subset guarantee holds precisely because the budget it compares is the budget
`match` enforces, so the formula must never fork.
*/
uint typoBudget(size_t length, uint configured) @safe pure nothrow @nogc
{
    if (configured == 0 || length < 2)
        return 0;
    auto derived = length / 4;
    if (derived == 0)
        derived = 1;
    if (derived > length - 1)
        derived = length - 1;
    return cast(uint)(derived < configured ? derived : configured);
}

@("fuzzy.common.typoBudgetPolicy")
@safe pure nothrow @nogc
unittest
{
    assert(typoBudget(0, 6) == 0);
    assert(typoBudget(1, 6) == 0);
    assert(typoBudget(2, 6) == 1);
    assert(typoBudget(2, 0) == 0);
    assert(typoBudget(8, 6) == 2);
    assert(typoBudget(11, 6) == 2);
    assert(typoBudget(12, 6) == 3);
    assert(typoBudget(64, 6) == 6);
    assert(typoBudget(64, 3) == 3);
}

/// Stable caller identity used instead of borrowed long-lived strings.
struct StableId
{
    ulong high;
    ulong low;

    int opCmp(in StableId other) const @safe pure nothrow @nogc
    {
        if (high != other.high)
            return high < other.high ? -1 : 1;
        if (low != other.low)
            return low < other.low ? -1 : 1;
        return 0;
    }
}

alias CandidateId = StableId;
alias ProjectId = StableId;
alias QueryId = StableId;
alias CorpusId = StableId;

/// How separators and drive prefixes in a candidate path are interpreted.
enum PathFlavor : ubyte
{
    unix,
    windows,
}

/// Candidate git-status bits. Multiple bits may be present.
enum GitStatus : ushort
{
    none = 0,
    modified = 1 << 0,
    untracked = 1 << 1,
    staged = 1 << 2,
    ignored = 1 << 3,
    clean = 1 << 4,
}

/// Built-in analysis profile selection.
enum AnalysisProfileKind : ubyte
{
    codePath,
    generalLanguage,
}

/// Profile plus the caller-owned vocabulary used by general-language mode.
struct AnalysisProfile
{
    AnalysisProfileKind kind = AnalysisProfileKind.codePath;
    StopwordLexicon stopwords;

    static AnalysisProfile codePath() @safe pure nothrow @nogc
        => AnalysisProfile(AnalysisProfileKind.codePath);

    static AnalysisProfile generalLanguage(
        StopwordLexicon stopwords = StopwordLexicon.init)
        @safe pure nothrow @nogc
        => AnalysisProfile(AnalysisProfileKind.generalLanguage, stopwords);
}

/// Borrowed candidate metadata; no callback or resolver is consulted.
struct CandidateView
{
    CandidateId id;
    const(char)[] path;
    size_t filenameOffset;
    PathFlavor pathFlavor;
    GitStatus gitStatus;
    long recencyKey;
}

/// Validate the filename boundary and byte capacity of a candidate.
FuzzyExpected!CandidateView validateCandidate(Caps = DefaultFuzzyCaps)(
    CandidateView candidate, in FuzzyLimits limits)
    @safe pure nothrow @nogc
{
    const knownStatuses = cast(ushort) GitStatus.modified
        | cast(ushort) GitStatus.untracked
        | cast(ushort) GitStatus.staged
        | cast(ushort) GitStatus.ignored
        | cast(ushort) GitStatus.clean;
    if ((candidate.pathFlavor != PathFlavor.unix
            && candidate.pathFlavor != PathFlavor.windows)
        || (cast(ushort) candidate.gitStatus & ~knownStatuses) != 0)
        return fuzzyErr!CandidateView(FuzzyErrorCode.invalidCandidate);
    if (candidate.path.length > limits.maxCandidateBytes
        || candidate.path.length > Caps.maxCandidateBytes)
        return fuzzyErr!CandidateView(FuzzyErrorCode.candidateTooLong,
            candidate.path.length);
    if (candidate.filenameOffset > candidate.path.length)
        return fuzzyErr!CandidateView(FuzzyErrorCode.invalidCandidate,
            candidate.filenameOffset);
    if (candidate.filenameOffset != 0
        && !isPathSeparator(candidate.path[candidate.filenameOffset - 1],
            candidate.pathFlavor))
        return fuzzyErr!CandidateView(FuzzyErrorCode.invalidCandidate,
            candidate.filenameOffset, "filename offset must follow a separator");
    return fuzzyOk(candidate);
}

/// A half-open source byte range.
struct TextRange
{
    size_t start;
    size_t end;
}

bool isPathSeparator(char value, PathFlavor flavor)
    @safe pure nothrow @nogc
{
    return value == '/' || (flavor == PathFlavor.windows && value == '\\');
}

@("fuzzy.common.limitValidation")
@safe pure nothrow @nogc
unittest
{
    auto good = validateLimits();
    assert(good.hasValue);
    auto limits = FuzzyLimits.init;
    limits.maxQueryUnits = DefaultFuzzyCaps.maxQueryUnits + 1;
    assert(validateLimits(limits).error.code
        == FuzzyErrorCode.invalidConfiguration);

    CandidateView candidate;
    candidate.pathFlavor = cast(PathFlavor) ubyte.max;
    assert(validateCandidate(candidate, FuzzyLimits.init).error.code
        == FuzzyErrorCode.invalidCandidate);
    candidate.pathFlavor = PathFlavor.unix;
    candidate.gitStatus = cast(GitStatus) ushort.max;
    assert(validateCandidate(candidate, FuzzyLimits.init).error.code
        == FuzzyErrorCode.invalidCandidate);
}
