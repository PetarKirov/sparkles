/** Bounded query lexer, constraint grammar, locations, and evaluator. */
module sparkles.fuzzy.query;

import sparkles.base.text.analysis : AnalysisCase, AnalysisError,
    AnalysisOptions, AnalysisWorkspace, analyzeText;

import sparkles.fuzzy.common : AnalysisProfile, AnalysisProfileKind,
    CandidateView, DefaultFuzzyCaps, FuzzyError, FuzzyErrorCode,
    FuzzyExpected, FuzzyLimits, GitStatus, PathFlavor, fuzzyErr, fuzzyOk,
    isPathSeparator, typoBudget, validateCandidate, validateLimits;
import sparkles.fuzzy.glob : GlobInstruction, GlobMatchWorkspace, GlobProgram,
    GlobProgramView, GlobRange, compileGlob, globMatch;

import sparkles.test_runner.attributes : benchmark;

/// A borrowed raw token span plus logical decoded trimming.
struct QueryText
{
    const(char)[] raw;
    size_t skipFront;
    size_t skipBack;

    /// Number of decoded bytes after quotes/escapes and logical trimming.
    size_t decodedLength() const scope @safe pure nothrow @nogc
    {
        const total = rawDecodedLength(raw);
        return skipFront <= total && skipBack <= total - skipFront
            ? total - skipFront - skipBack : 0;
    }

    /// Cursor over decoded bytes. Quotes disappear and backslash quotes one byte.
    DecodedQueryCursor cursor() const return scope @safe pure nothrow @nogc
        => makeDecodedCursor(this);

    QueryText dropFront(size_t count) const return scope @safe pure nothrow @nogc
    {
        const next = count > size_t.max - skipFront
            ? size_t.max : skipFront + count;
        return QueryText(raw, next, skipBack);
    }

    QueryText dropBack(size_t count) const return scope @safe pure nothrow @nogc
    {
        const next = count > size_t.max - skipBack
            ? size_t.max : skipBack + count;
        return QueryText(raw, skipFront, next);
    }

    /// Decode into fixed caller storage.
    FuzzyExpected!size_t decodeInto(size_t N)(ref char[N] output) const
        scope @safe pure nothrow @nogc
    {
        auto input = cursor();
        size_t length;
        while (!input.empty)
        {
            if (length == N)
                return fuzzyErr!size_t(FuzzyErrorCode.queryTooComplex,
                    raw.length);
            output[length++] = cast(char) input.front;
            input.popFront();
        }
        return fuzzyOk(length);
    }

    /**
    Decode for the glob compiler while preserving query-language escapes.

    Quotes still disappear, but every byte quoted by a query backslash is
    emitted with a glob backslash so `glob:\*` means a literal asterisk rather
    than becoming a wildcard after token decoding.
    */
    FuzzyExpected!size_t decodeGlobInto(size_t N)(ref char[N] output) const
        scope @safe pure nothrow @nogc
    {
        auto input = cursor();
        size_t length;
        while (!input.empty)
        {
            if (input.escaped)
            {
                if (length == N)
                    return fuzzyErr!size_t(FuzzyErrorCode.queryTooComplex,
                        raw.length);
                output[length++] = '\\';
            }
            if (length == N)
                return fuzzyErr!size_t(FuzzyErrorCode.queryTooComplex,
                    raw.length);
            output[length++] = cast(char) input.front;
            input.popFront();
        }
        return fuzzyOk(length);
    }
}

/// Input range over one `QueryText`'s decoded bytes.
struct DecodedQueryCursor
{
    private const(char)[] raw_;
    private size_t at_;
    private size_t skip_;
    private size_t remaining_;
    private ubyte front_;
    private bool frontEscaped_;
    private bool empty_ = true;

private:
    this(QueryText text) @trusted pure nothrow @nogc
    {
        raw_ = text.raw;
        skip_ = text.skipFront;
        const total = rawDecodedLength(raw_);
        remaining_ = text.skipFront <= total
                && text.skipBack <= total - text.skipFront
            ? total - text.skipFront - text.skipBack : 0;
        advance();
    }

    bool empty() const scope @safe pure nothrow @nogc => empty_;
    ubyte front() const scope @safe pure nothrow @nogc => front_;

    /// Whether the current byte was quoted by a query backslash.
    bool escaped() const scope @safe pure nothrow @nogc => frontEscaped_;

    void popFront() scope @safe pure nothrow @nogc
    {
        if (!empty_)
            advance();
    }

private:
    void advance() scope @safe pure nothrow @nogc
    {
        empty_ = true;
        while (at_ < raw_.length)
        {
            ubyte value = cast(ubyte) raw_[at_++];
            if (value == '"')
                continue;
            bool escaped;
            if (value == '\\' && at_ < raw_.length)
            {
                escaped = true;
                value = cast(ubyte) raw_[at_++];
            }
            if (skip_ != 0)
            {
                --skip_;
                continue;
            }
            if (remaining_ == 0)
                return;
            --remaining_;
            front_ = value;
            frontEscaped_ = escaped;
            empty_ = false;
            return;
        }
    }
}

private DecodedQueryCursor makeDecodedCursor(return scope QueryText text)
    @trusted pure nothrow @nogc
    => DecodedQueryCursor(text);

/// Parsed constraint category.
enum ConstraintKind : ubyte
{
    extension,
    glob,
    pathSegment,
    filePath,
    gitStatus,
}

/// One parsed constraint. Text remains borrowed through `QueryText`.
struct Constraint
{
    ConstraintKind kind;
    bool negated;
    GitStatus status;
    QueryText value;
}

/// Parsed source location.
struct Location
{
    uint startLine;
    uint startColumn;
    uint endLine;
    uint endColumn;
    bool hasColumn;
    bool hasEnd;

    bool present() const @safe pure nothrow @nogc => startLine != 0;
}

/// Non-fatal parser diagnostics.
struct QueryDiagnostics
{
    size_t droppedParts;
}

/// Query parsing policy.
struct QueryParseOptions
{
    AnalysisProfile profile = AnalysisProfile.codePath();
    PathFlavor pathFlavor = PathFlavor.unix;
    FuzzyLimits limits;
}

private struct StoredGlob
{
    size_t instructionStart;
    size_t instructionCount;
    size_t rangeStart;
    size_t rangeCount;
}

/** A bounded regular query value with borrowed source slices. */
struct QueryStorage(Caps = DefaultFuzzyCaps)
{
    private const(char)[] source_;
    private QueryText[Caps.maxFuzzyParts] fuzzyParts_;
    private Constraint[Caps.maxConstraints] constraints_;
    private StoredGlob[Caps.maxConstraints] storedGlobs_;
    private GlobInstruction[Caps.maxGlobInstructions] globInstructions_ = void;
    private GlobRange[Caps.maxGlobRanges] globRanges_ = void;
    private size_t globInstructionCount_;
    private size_t globRangeCount_;
    private size_t fuzzyPartCount_;
    private size_t constraintCount_;
    private Location location_;
    private QueryDiagnostics diagnostics_;
    private AnalysisProfile profile_;
    private PathFlavor pathFlavor_;

    const(char)[] source() const return scope @safe pure nothrow @nogc
        => source_;
    const(QueryText)[] fuzzyParts() const return scope
        @safe pure nothrow @nogc
        => queryFuzzyParts(this);
    const(Constraint)[] constraints() const return scope
        @safe pure nothrow @nogc
        => queryConstraints(this);
    Location location() const @safe pure nothrow @nogc => location_;
    QueryDiagnostics diagnostics() const @safe pure nothrow @nogc
        => diagnostics_;
    AnalysisProfile profile() const return scope @safe pure nothrow @nogc
        => profile_;
    PathFlavor pathFlavor() const @safe pure nothrow @nogc => pathFlavor_;
    bool hasFuzzyParts() const @safe pure nothrow @nogc
        => fuzzyPartCount_ != 0;

private:
    GlobProgramView globAt(size_t constraintIndex) const return scope
        @trusted pure nothrow @nogc
    {
        const stored = storedGlobs_[constraintIndex];
        return GlobProgramView(
            globInstructions_[stored.instructionStart
                .. stored.instructionStart + stored.instructionCount],
            globRanges_[stored.rangeStart
                .. stored.rangeStart + stored.rangeCount],
            pathFlavor_, false);
    }
}

// Keep default per-generation storage reviewable; changing capacities or
// instruction layout must explicitly revisit the memory budget.
static assert(QueryStorage!().sizeof <= 128 * 1_024);

private const(QueryText)[] queryFuzzyParts(Caps)(
    return scope ref const QueryStorage!Caps query)
    @trusted pure nothrow @nogc
    => query.fuzzyParts_[0 .. query.fuzzyPartCount_];

private const(Constraint)[] queryConstraints(Caps)(
    return scope ref const QueryStorage!Caps query)
    @trusted pure nothrow @nogc
    => query.constraints_[0 .. query.constraintCount_];

/// Read-only name retained for APIs that conceptually consume a query view.
alias QueryView(Caps = DefaultFuzzyCaps) = QueryStorage!Caps;

/**
Conservative survivor-refinement predicate for ASCII incremental typing.

It returns `false` whenever a profile/constraint changes, a part is reordered,
Unicode analysis could alter unit counts, or the derived typo budget grows.
False negatives merely request a full corpus scan; a `true` result guarantees
the new admitted set is a subset of the old one.
*/
bool refines(Caps = DefaultFuzzyCaps)(in QueryStorage!Caps current,
    in QueryStorage!Caps previous,
    uint configuredMaximum = DefaultFuzzyCaps.maxTypos)
    @safe pure nothrow @nogc
{
    if (current.profile.kind != previous.profile.kind
        || current.pathFlavor != previous.pathFlavor
        || current.profile.stopwords.words.ptr
            != previous.profile.stopwords.words.ptr
        || current.profile.stopwords.words.length
            != previous.profile.stopwords.words.length
        || current.constraints.length != previous.constraints.length
        || current.fuzzyParts.length != previous.fuzzyParts.length)
        return false;
    foreach (i; 0 .. current.constraints.length)
    {
        const left = current.constraints[i];
        const right = previous.constraints[i];
        if (left.kind != right.kind || left.negated != right.negated
            || left.status != right.status
            || (left.kind == ConstraintKind.glob
                ? !decodedGlobEqual(left.value, right.value)
                : !decodedEqual(left.value, right.value)))
            return false;
    }
    foreach (i; 0 .. current.fuzzyParts.length)
    {
        const newer = current.fuzzyParts[i];
        const older = previous.fuzzyParts[i];
        if (!decodedIsAscii(older) || !decodedIsAscii(newer)
            || !decodedPrefix(older, newer))
            return false;
        const oldBudget = typoBudget(older.decodedLength, configuredMaximum);
        const newBudget = typoBudget(newer.decodedLength, configuredMaximum);
        if (newBudget > oldBudget)
            return false;
    }
    return true;
}

private enum DispatchKind : ubyte
{
    fuzzy,
    constraint,
    error,
}

private struct DispatchResult
{
    DispatchKind kind;
    Constraint constraint;
    FuzzyError error;
}

/** Parse arbitrary keystrokes into a bounded query. */
FuzzyExpected!(QueryStorage!Caps) parseQuery(Caps = DefaultFuzzyCaps)(
    return scope const(char)[] source,
    QueryParseOptions options = QueryParseOptions.init)
    @safe pure nothrow @nogc
{
    // The implementation's only trust is the Expected value carrying the
    // explicitly `return scope` input slice through DIP1000.
    return parseQueryImpl!Caps(source, options);
}

private FuzzyExpected!(QueryStorage!Caps) parseQueryImpl(Caps)(
    return scope const(char)[] source, QueryParseOptions options)
    @trusted pure nothrow @nogc
{
    if (options.limits.maxQueryUnits == 0)
        options.limits = FuzzyLimits.init;
    if ((options.profile.kind != AnalysisProfileKind.codePath
            && options.profile.kind != AnalysisProfileKind.generalLanguage)
        || (options.pathFlavor != PathFlavor.unix
            && options.pathFlavor != PathFlavor.windows))
        return fuzzyErr!(QueryStorage!Caps)(
            FuzzyErrorCode.invalidConfiguration);
    auto validated = validateLimits!Caps(options.limits);
    if (validated.hasError)
        return fuzzyErr!(QueryStorage!Caps)(validated.error.code);
    if (source.length > options.limits.maxQueryBytes)
        return fuzzyErr!(QueryStorage!Caps)(FuzzyErrorCode.queryTooComplex,
            options.limits.maxQueryBytes);

    QueryStorage!Caps query;
    query.source_ = source;
    query.profile_ = options.profile;
    query.pathFlavor_ = options.pathFlavor;

    size_t at;
    while (at < source.length)
    {
        while (at < source.length && isAsciiSpace(source[at]))
            ++at;
        if (at == source.length)
            break;
        const start = at;
        bool quoted;
        while (at < source.length)
        {
            const value = source[at];
            if (value == '\\')
            {
                if (at + 1 == source.length)
                    return fuzzyErr!(QueryStorage!Caps)(
                        FuzzyErrorCode.invalidEscape, at);
                at += 2;
                continue;
            }
            if (value == '"')
            {
                quoted = !quoted;
                ++at;
                continue;
            }
            if (!quoted && isAsciiSpace(value))
                break;
            ++at;
        }
        if (quoted)
            return fuzzyErr!(QueryStorage!Caps)(
                FuzzyErrorCode.unexpectedEnd, at, "unclosed quote");

        auto token = QueryText(source[start .. at]);
        auto dispatched = dispatchToken(token);
        if (dispatched.kind == DispatchKind.error)
            return fuzzyErr!(QueryStorage!Caps)(dispatched.error.code,
                start + dispatched.error.offset, dispatched.error.context);
        if (dispatched.kind == DispatchKind.constraint)
        {
            if (query.constraintCount_ == options.limits.maxConstraints)
                return fuzzyErr!(QueryStorage!Caps)(
                    FuzzyErrorCode.queryTooComplex, start,
                    "too many constraints");
            if (dispatched.constraint.kind == ConstraintKind.glob)
            {
                auto stored = storeCompiledGlob(dispatched.constraint.value,
                    options, query.constraintCount_, query);
                if (stored.hasError)
                    return fuzzyErr!(QueryStorage!Caps)(stored.error.code,
                        start + stored.error.offset, stored.error.context);
            }
            query.constraints_[query.constraintCount_++] = dispatched.constraint;
        }
        else
        {
            if (query.fuzzyPartCount_ == options.limits.maxFuzzyParts)
                return fuzzyErr!(QueryStorage!Caps)(
                    FuzzyErrorCode.queryTooComplex, start,
                    "too many fuzzy parts");
            query.fuzzyParts_[query.fuzzyPartCount_++] = token;
        }
    }

    if (query.fuzzyPartCount_ != 0)
    {
        ref last = query.fuzzyParts_[query.fuzzyPartCount_ - 1];
        Location location;
        size_t suffixBytes;
        ubyte[Caps.maxQueryBytes] locationValues = void;
        bool[Caps.maxQueryBytes] locationEscaped = void;
        auto parsed = parseLocationSuffix(last, options.pathFlavor,
            locationValues[], locationEscaped[], location, suffixBytes);
        if (parsed.hasError)
            return fuzzyErr!(QueryStorage!Caps)(parsed.error.code,
                parsed.error.offset, parsed.error.context);
        if (parsed.value)
        {
            last = last.dropBack(suffixBytes);
            query.location_ = location;
            if (last.decodedLength == 0)
                --query.fuzzyPartCount_;
        }
    }
    auto diagnosed = diagnoseFuzzyParts(query, options.limits);
    if (diagnosed.hasError)
        return fuzzyErr!(QueryStorage!Caps)(diagnosed.error.code,
            diagnosed.error.offset, diagnosed.error.context);
    return fuzzyOk(query);
}

private FuzzyExpected!void storeCompiledGlob(Caps)(QueryText text,
    in QueryParseOptions options, size_t constraintIndex,
    ref QueryStorage!Caps query) @safe pure nothrow @nogc
{
    char[Caps.maxQueryBytes] decoded = void;
    auto decodedLength = text.decodeGlobInto(decoded);
    if (decodedLength.hasError)
        return fuzzyErr!void(decodedLength.error.code,
            decodedLength.error.offset, decodedLength.error.context);
    GlobProgram!(Caps.maxGlobInstructions, Caps.maxGlobRanges) program;
    auto compiled = compileGlob(decoded[0 .. decodedLength.value],
        options.pathFlavor, false, program);
    if (compiled.hasError)
        return fuzzyErr!void(compiled.error.code, compiled.error.offset,
            compiled.error.context);

    const instructions = program.instructions;
    const ranges = program.ranges;
    if (instructions.length > options.limits.maxGlobInstructions
        - query.globInstructionCount_
        || ranges.length > options.limits.maxGlobRanges
            - query.globRangeCount_)
        return fuzzyErr!void(FuzzyErrorCode.globTooComplex, text.raw.length,
            "combined glob arena is full");
    query.storedGlobs_[constraintIndex] = StoredGlob(
        query.globInstructionCount_, instructions.length,
        query.globRangeCount_, ranges.length);
    foreach (instruction; instructions)
        query.globInstructions_[query.globInstructionCount_++] = instruction;
    foreach (range; ranges)
        query.globRanges_[query.globRangeCount_++] = range;
    return fuzzyOk();
}

private FuzzyExpected!void diagnoseFuzzyParts(Caps)(
    ref QueryStorage!Caps query, in FuzzyLimits limits)
    @safe pure nothrow @nogc
{
    char[Caps.maxQueryBytes] decoded = void;
    AnalysisWorkspace!(Caps.maxQueryUnits,
        Caps.maxNormalizationSegment) analysis;
    bool sensitive;
    if (query.profile_.kind == AnalysisProfileKind.codePath)
    {
        foreach (part; query.fuzzyParts)
        {
            auto bytes = part.decodeInto(decoded);
            if (bytes.hasError)
                return fuzzyErr!void(bytes.error.code, bytes.error.offset);
            auto probe = analyzeText(decoded[0 .. bytes.value],
                AnalysisOptions.codePath(AnalysisCase.sensitive), analysis);
            if (!probe.succeeded)
                return queryAnalysisError(probe.error, probe.sourceOffset);
            sensitive |= probe.containsUppercase;
        }
    }

    AnalysisOptions analysisOptions;
    final switch (query.profile_.kind)
    {
    case AnalysisProfileKind.codePath:
        analysisOptions = AnalysisOptions.codePath(sensitive
            ? AnalysisCase.sensitive : AnalysisCase.simpleFold);
        break;
    case AnalysisProfileKind.generalLanguage:
        analysisOptions = AnalysisOptions.generalLanguage(
            query.profile_.stopwords);
        break;
    }
    size_t totalUnits;
    foreach (part; query.fuzzyParts)
    {
        auto bytes = part.decodeInto(decoded);
        if (bytes.hasError)
            return fuzzyErr!void(bytes.error.code, bytes.error.offset);
        auto analyzed = analyzeText(decoded[0 .. bytes.value],
            analysisOptions, analysis);
        if (!analyzed.succeeded)
            return queryAnalysisError(analyzed.error, analyzed.sourceOffset);
        if (analysis.output.length < 2)
        {
            ++query.diagnostics_.droppedParts;
            continue;
        }
        if (analysis.output.length > limits.maxQueryUnits
            || totalUnits > limits.maxQueryUnits - analysis.output.length)
            return fuzzyErr!void(FuzzyErrorCode.queryTooComplex, totalUnits);
        totalUnits += analysis.output.length;
    }
    return fuzzyOk();
}

private FuzzyExpected!void queryAnalysisError(AnalysisError error,
    size_t offset) @safe pure nothrow @nogc
{
    final switch (error)
    {
    case AnalysisError.none:
        return fuzzyOk();
    case AnalysisError.invalidOptions:
        return fuzzyErr!void(FuzzyErrorCode.invalidConfiguration, offset);
    case AnalysisError.sourceTooLong:
    case AnalysisError.outputFull:
        return fuzzyErr!void(FuzzyErrorCode.queryTooComplex, offset);
    case AnalysisError.segmentTooLong:
        return fuzzyErr!void(FuzzyErrorCode.normalizationSegmentTooLong,
            offset);
    }
}

private DispatchResult dispatchToken(QueryText original)
    @safe pure nothrow @nogc
{
    if (original.decodedLength == 0)
        return DispatchResult(DispatchKind.fuzzy);

    if (decodedFirst(original) == '!' && !decodedEscapedAt(original, 0))
    {
        auto inner = original.dropFront(1);
        auto nested = dispatchPositive(inner);
        if (nested.kind == DispatchKind.constraint)
        {
            nested.constraint.negated = true;
            return nested;
        }
        if (nested.kind == DispatchKind.error)
            return nested;
        return DispatchResult(DispatchKind.fuzzy);
    }
    return dispatchPositive(original);
}

private DispatchResult dispatchPositive(QueryText token)
    @safe pure nothrow @nogc
{
    Constraint constraint;
    if (decodedStartsWith(token, "type:"))
        return dispatchError(FuzzyErrorCode.unknownValue, 0,
            "type: is reserved but unsupported");
    if (decodedStartsWith(token, "ext:"))
    {
        constraint.kind = ConstraintKind.extension;
        constraint.value = token.dropFront(4);
        return checkedConstraint(constraint);
    }
    if (decodedStartsWith(token, "path:"))
    {
        constraint.kind = ConstraintKind.filePath;
        constraint.value = token.dropFront(5);
        return checkedConstraint(constraint);
    }
    if (decodedStartsWith(token, "seg:"))
    {
        constraint.kind = ConstraintKind.pathSegment;
        constraint.value = token.dropFront(4);
        return checkedConstraint(constraint);
    }
    if (decodedStartsWith(token, "glob:"))
    {
        constraint.kind = ConstraintKind.glob;
        constraint.value = token.dropFront(5);
        return checkedConstraint(constraint);
    }

    foreach (prefix; ["status:", "git:", "st:", "g:"])
    {
        if (decodedStartsWith(token, prefix))
        {
            constraint.kind = ConstraintKind.gitStatus;
            constraint.value = token.dropFront(prefix.length);
            auto status = parseGitStatus(constraint.value);
            if (status.hasError)
                return DispatchResult(DispatchKind.error,
                    Constraint.init, status.error);
            constraint.status = status.value;
            return DispatchResult(DispatchKind.constraint, constraint);
        }
    }

    if (decodedStartsWith(token, "*.")
        && !decodedEscapedAt(token, 0)
        && !decodedContainsUnescapedMeta(token.dropFront(2)))
    {
        constraint.kind = ConstraintKind.extension;
        constraint.value = token.dropFront(2);
        return checkedConstraint(constraint);
    }

    const first = decodedFirst(token);
    const last = decodedLast(token);
    const firstIsSeparator = (first == '/' || first == '\\')
        && !decodedEscapedAt(token, 0);
    const lastIsSeparator = (last == '/' || last == '\\')
        && !decodedEscapedAt(token, token.decodedLength - 1);
    if ((firstIsSeparator || lastIsSeparator)
        && token.decodedLength > 1)
    {
        constraint.kind = ConstraintKind.pathSegment;
        constraint.value = token;
        if (firstIsSeparator)
            constraint.value = constraint.value.dropFront(1);
        if (lastIsSeparator)
            constraint.value = constraint.value.dropBack(1);
        return checkedConstraint(constraint);
    }
    if (decodedContainsUnescapedMeta(token))
    {
        constraint.kind = ConstraintKind.glob;
        constraint.value = token;
        return checkedConstraint(constraint);
    }
    return DispatchResult(DispatchKind.fuzzy);
}

private DispatchResult checkedConstraint(Constraint constraint)
    @safe pure nothrow @nogc
{
    return constraint.value.decodedLength == 0
        ? dispatchError(FuzzyErrorCode.emptyValue)
        : DispatchResult(DispatchKind.constraint, constraint);
}

private DispatchResult dispatchError(FuzzyErrorCode code, size_t offset = 0,
    string context = null) @safe pure nothrow @nogc
    => DispatchResult(DispatchKind.error, Constraint.init,
        FuzzyError(code, offset, context));

private FuzzyExpected!GitStatus parseGitStatus(QueryText text)
    @safe pure nothrow @nogc
{
    if (text.decodedLength == 0)
        return fuzzyErr!GitStatus(FuzzyErrorCode.emptyValue);
    static immutable names = [
        "modified", "untracked", "staged", "ignored", "clean",
    ];
    static immutable values = [
        GitStatus.modified, GitStatus.untracked, GitStatus.staged,
        GitStatus.ignored, GitStatus.clean,
    ];
    size_t found;
    GitStatus result;
    foreach (i, name; names)
    {
        if (decodedIsAsciiPrefixOf(text, name))
        {
            ++found;
            result = values[i];
        }
    }
    if (found == 0)
        return fuzzyErr!GitStatus(FuzzyErrorCode.unknownValue);
    if (found > 1)
        return fuzzyErr!GitStatus(FuzzyErrorCode.ambiguousValue);
    return fuzzyOk(result);
}

/// Scratch storage for constraint evaluation.
struct ConstraintWorkspace(Caps = DefaultFuzzyCaps)
{
    private char[Caps.maxQueryBytes] decoded = void;
    private GlobMatchWorkspace!(Caps.maxGlobInstructions,
        Caps.maxCandidateUnits, Caps.maxNormalizationSegment) globMatch;
}

static assert(ConstraintWorkspace!().sizeof <= 128 * 1_024);

/** Evaluate every parsed constraint over concrete candidate metadata. */
FuzzyExpected!bool evaluateConstraints(Caps = DefaultFuzzyCaps)(
    in QueryStorage!Caps query, in CandidateView candidate,
    ref ConstraintWorkspace!Caps workspace,
    FuzzyLimits limits = FuzzyLimits.init) @safe pure nothrow @nogc
{
    auto checkedLimits = validateLimits!Caps(limits);
    if (checkedLimits.hasError)
        return fuzzyErr!bool(checkedLimits.error.code,
            checkedLimits.error.offset, checkedLimits.error.context);
    auto checkedCandidate = validateCandidate!Caps(candidate,
        checkedLimits.value);
    if (checkedCandidate.hasError)
        return fuzzyErr!bool(checkedCandidate.error.code,
            checkedCandidate.error.offset, checkedCandidate.error.context);

    bool positiveExtensionSeen;
    bool positiveExtensionMatched;
    foreach (constraintIndex, constraint; query.constraints)
    {
        const(char)[] value;
        if (constraint.kind != ConstraintKind.glob)
        {
            auto decoded = constraint.value.decodeInto(workspace.decoded);
            if (decoded.hasError)
                return fuzzyErr!bool(decoded.error.code, decoded.error.offset);
            value = workspace.decoded[0 .. decoded.value];
        }
        bool matched;
        final switch (constraint.kind)
        {
        case ConstraintKind.extension:
            matched = extensionMatches(candidate.path, candidate.filenameOffset,
                value, false);
            if (!constraint.negated)
            {
                positiveExtensionSeen = true;
                positiveExtensionMatched |= matched;
                continue;
            }
            break;
        case ConstraintKind.pathSegment:
            matched = segmentMatches(candidate.path, value,
                query.pathFlavor, false);
            break;
        case ConstraintKind.filePath:
            matched = pathSuffixMatches(candidate.path, value,
                query.pathFlavor, false);
            break;
        case ConstraintKind.gitStatus:
            matched = (cast(ushort) candidate.gitStatus
                & cast(ushort) constraint.status) != 0;
            break;
        case ConstraintKind.glob:
            auto globbed = globMatch(query.globAt(constraintIndex),
                candidate.path,
                workspace.globMatch);
            if (globbed.hasError)
                return globbed;
            matched = globbed.value;
            break;
        }
        if (constraint.negated ? matched : !matched)
            return fuzzyOk(false);
    }
    return fuzzyOk(!positiveExtensionSeen || positiveExtensionMatched);
}

private bool extensionMatches(scope const(char)[] path, size_t filenameOffset,
    scope const(char)[] extension, bool caseSensitive)
    @safe pure nothrow @nogc
{
    const filename = path[filenameOffset .. $];
    if (extension.length == 0)
        return false;
    if (extension[0] == '.')
        return suffixEquals(filename, extension, PathFlavor.unix, caseSensitive);
    if (filename.length <= extension.length
        || filename[filename.length - extension.length - 1] != '.')
        return false;
    return bytesEqual(filename[$ - extension.length .. $], extension,
        PathFlavor.unix, caseSensitive);
}

private bool pathSuffixMatches(scope const(char)[] path,
    scope const(char)[] suffix, PathFlavor flavor, bool caseSensitive)
    @safe pure nothrow @nogc
{
    if (!suffixEquals(path, suffix, flavor, caseSensitive))
        return false;
    const start = path.length - suffix.length;
    return start == 0 || isPathSeparator(path[start - 1], flavor)
        || isPathSeparator(suffix[0], flavor);
}

private bool segmentMatches(scope const(char)[] path,
    scope const(char)[] wanted, PathFlavor flavor, bool caseSensitive)
    @safe pure nothrow @nogc
{
    if (wanted.length == 0 || wanted.length > path.length)
        return false;
    foreach (start; 0 .. path.length - wanted.length + 1)
    {
        if (start != 0 && !isPathSeparator(path[start - 1], flavor))
            continue;
        if (!bytesEqual(path[start .. start + wanted.length], wanted,
                flavor, caseSensitive))
            continue;
        const end = start + wanted.length;
        if (end == path.length || isPathSeparator(path[end], flavor))
            return true;
    }
    return false;
}

private bool suffixEquals(scope const(char)[] text, scope const(char)[] suffix,
    PathFlavor flavor, bool caseSensitive) @safe pure nothrow @nogc
{
    return text.length >= suffix.length
        && bytesEqual(text[$ - suffix.length .. $], suffix, flavor, caseSensitive);
}

private bool bytesEqual(scope const(char)[] left, scope const(char)[] right,
    PathFlavor flavor, bool caseSensitive) @safe pure nothrow @nogc
{
    if (left.length != right.length)
        return false;
    foreach (i; 0 .. left.length)
    {
        if (isPathSeparator(left[i], flavor)
            && isPathSeparator(right[i], flavor))
            continue;
        if (caseSensitive ? left[i] != right[i]
            : asciiLower(left[i]) != asciiLower(right[i]))
            return false;
    }
    return true;
}

private FuzzyExpected!bool parseLocationSuffix(QueryText text,
    PathFlavor pathFlavor, scope ubyte[] valueScratch,
    scope bool[] escapedScratch, out Location location,
    out size_t suffixBytes) @safe pure nothrow @nogc
in (text.decodedLength <= valueScratch.length
    && text.decodedLength <= escapedScratch.length,
    "location scratch must cover the token's decoded length")
{
    location = Location.init;
    suffixBytes = 0;
    const length = text.decodedLength;
    if (length == 0)
        return fuzzyOk(false);

    // Decode the token once; every helper below indexes the scratch in O(1),
    // keeping the whole suffix parse linear in the token length.
    {
        auto input = text.cursor();
        size_t at;
        while (!input.empty)
        {
            valueScratch[at] = input.front;
            escapedScratch[at] = input.escaped;
            ++at;
            input.popFront();
        }
    }
    const values = valueScratch[0 .. length];
    const escaped = escapedScratch[0 .. length];

    // Parenthesized `(line,column)` form.
    if (values[length - 1] == ')' && !escaped[length - 1])
    {
        size_t open = length;
        foreach (i; 0 .. length)
            if (values[i] == '(' && !escaped[i])
                open = i;
        if (open < length)
        {
            auto parsed = parseLocationBody(values, open + 1, length - 1,
                ',', location);
            if (parsed.hasError)
                return parsed;
            if (parsed.value)
            {
                suffixBytes = length - open;
                return fuzzyOk(true);
            }
        }
    }

    // Try each colon whose complete tail is one accepted numeric grammar. The
    // first success preserves the largest location (`:line:column` rather than
    // treating only the final `:column` as a line). Only the last few colons
    // can begin a valid tail: a successful tail contains at most two further
    // colons by value (`line:column-line:column`), and parseLocationBody
    // rejects a third before ever reaching a digit — so a colon with more
    // than three colons after it is guaranteed to fail with no observable
    // side effect. Keeping the last four candidates preserves the
    // earliest-colon-wins rule while bounding the attempts to a constant.
    size_t[4] colonAt = void;
    size_t colonCount;
    foreach (i; 0 .. length)
    {
        if (values[i] != ':' || escaped[i])
            continue;
        if (pathFlavor == PathFlavor.windows && i == 1
            && isAsciiLetter(values[0]))
            continue;
        if (colonCount == colonAt.length)
        {
            foreach (k; 1 .. colonAt.length)
                colonAt[k - 1] = colonAt[k];
            --colonCount;
        }
        colonAt[colonCount++] = i;
    }
    foreach (k; 0 .. colonCount)
    {
        const i = colonAt[k];
        Location candidate;
        auto parsed = parseColonLocation(values, i + 1, length, candidate);
        if (parsed.hasError)
            return parsed;
        if (parsed.value)
        {
            location = candidate;
            suffixBytes = length - i;
            return fuzzyOk(true);
        }
    }
    return fuzzyOk(false);
}

private FuzzyExpected!bool parseColonLocation(scope const(ubyte)[] values,
    size_t start, size_t end, out Location location) @safe pure nothrow @nogc
{
    size_t dash = end;
    foreach (i; start .. end)
        if (values[i] == '-')
            dash = i;
    if (dash < end)
    {
        Location left;
        Location right;
        auto first = parseLocationBody(values, start, dash, ':', left);
        auto second = parseLocationBody(values, dash + 1, end, ':', right);
        if (first.hasError)
            return first;
        if (second.hasError)
            return second;
        if (!first.value || !second.value)
            return fuzzyOk(false);
        location = left;
        location.endLine = right.startLine;
        location.endColumn = right.startColumn;
        location.hasEnd = true;
        return fuzzyOk(true);
    }
    return parseLocationBody(values, start, end, ':', location);
}

private FuzzyExpected!bool parseLocationBody(scope const(ubyte)[] values,
    size_t start, size_t end, ubyte separator, out Location location)
    @safe pure nothrow @nogc
{
    location = Location.init;
    if (start >= end)
        return fuzzyOk(false);
    size_t split = end;
    foreach (i; start .. end)
        if (values[i] == separator)
        {
            if (split != end)
                return fuzzyOk(false);
            split = i;
        }
    auto line = parseUint(values, start, split);
    if (line.hasError)
        return line.error.code == FuzzyErrorCode.numericOverflow
            ? fuzzyErr!bool(line.error.code, line.error.offset)
            : fuzzyOk(false);
    if (line.value == 0)
        return fuzzyOk(false);
    location.startLine = line.value;
    if (split != end)
    {
        auto column = parseUint(values, split + 1, end);
        if (column.hasError)
            return column.error.code == FuzzyErrorCode.numericOverflow
                ? fuzzyErr!bool(column.error.code, column.error.offset)
                : fuzzyOk(false);
        if (column.value == 0)
            return fuzzyOk(false);
        location.startColumn = column.value;
        location.hasColumn = true;
    }
    return fuzzyOk(true);
}

private FuzzyExpected!uint parseUint(scope const(ubyte)[] values, size_t start,
    size_t end) @safe pure nothrow @nogc
{
    if (start >= end)
        return fuzzyErr!uint(FuzzyErrorCode.unexpectedCharacter, start);
    uint value;
    foreach (i; start .. end)
    {
        const c = values[i];
        if (c < '0' || c > '9')
            return fuzzyErr!uint(FuzzyErrorCode.unexpectedCharacter, i);
        const digit = c - '0';
        if (value > (uint.max - digit) / 10)
            return fuzzyErr!uint(FuzzyErrorCode.numericOverflow, i);
        value = value * 10 + digit;
    }
    return fuzzyOk(value);
}

private size_t rawDecodedLength(scope const(char)[] raw)
    @safe pure nothrow @nogc
{
    size_t result;
    size_t i;
    while (i < raw.length)
    {
        if (raw[i] == '"')
        {
            ++i;
            continue;
        }
        if (raw[i] == '\\' && i + 1 < raw.length)
            ++i;
        ++i;
        ++result;
    }
    return result;
}

private struct DecodedByteInfo
{
    ubyte value;
    bool escaped;
}

private DecodedByteInfo decodedInfoAt(QueryText text, size_t wanted)
    @safe pure nothrow @nogc
{
    const total = rawDecodedLength(text.raw);
    if (text.skipFront > total || text.skipBack > total - text.skipFront)
        return DecodedByteInfo.init;
    const first = cast(size_t) text.skipFront;
    const pastLast = total >= text.skipBack ? total - text.skipBack : 0;
    size_t logical;
    size_t i;
    while (i < text.raw.length)
    {
        auto value = cast(ubyte) text.raw[i++];
        if (value == '"')
            continue;
        bool escaped;
        if (value == '\\' && i < text.raw.length)
        {
            escaped = true;
            value = cast(ubyte) text.raw[i++];
        }
        if (logical >= first && logical < pastLast
            && logical - first == wanted)
            return DecodedByteInfo(value, escaped);
        ++logical;
    }
    return DecodedByteInfo.init;
}

private ubyte decodedByteAt(QueryText text, size_t wanted)
    @safe pure nothrow @nogc
    => decodedInfoAt(text, wanted).value;

private bool decodedEscapedAt(QueryText text, size_t wanted)
    @safe pure nothrow @nogc
    => decodedInfoAt(text, wanted).escaped;

private ubyte decodedFirst(QueryText text) @safe pure nothrow @nogc
    => decodedByteAt(text, 0);

private ubyte decodedLast(QueryText text) @safe pure nothrow @nogc
    => text.decodedLength == 0 ? 0
        : decodedByteAt(text, text.decodedLength - 1);

private bool decodedStartsWith(QueryText text, scope const(char)[] prefix)
    @safe pure nothrow @nogc
{
    if (text.decodedLength < prefix.length)
        return false;
    auto cursor = text.cursor();
    foreach (value; prefix)
    {
        if (cursor.empty || cursor.front != value)
            return false;
        cursor.popFront();
    }
    return true;
}

private bool decodedIsAsciiPrefixOf(QueryText text, scope const(char)[] word)
    @safe pure nothrow @nogc
{
    if (text.decodedLength > word.length)
        return false;
    auto cursor = text.cursor();
    size_t i;
    while (!cursor.empty)
    {
        if (asciiLower(cast(char) cursor.front) != word[i++])
            return false;
        cursor.popFront();
    }
    return true;
}

private bool decodedContainsUnescapedMeta(QueryText text)
    @safe pure nothrow @nogc
{
    auto input = text.cursor();
    while (!input.empty)
    {
        if (!input.escaped && (input.front == '*' || input.front == '?'
                || input.front == '[' || input.front == '{'))
            return true;
        input.popFront();
    }
    return false;
}

private bool decodedEqual(QueryText left, QueryText right)
    @safe pure nothrow @nogc
{
    if (left.decodedLength != right.decodedLength)
        return false;
    auto a = left.cursor();
    auto b = right.cursor();
    while (!a.empty)
    {
        if (a.front != b.front)
            return false;
        a.popFront();
        b.popFront();
    }
    return true;
}

private bool decodedGlobEqual(QueryText left, QueryText right)
    @safe pure nothrow @nogc
{
    if (left.decodedLength != right.decodedLength)
        return false;
    auto a = left.cursor();
    auto b = right.cursor();
    while (!a.empty)
    {
        if (a.front != b.front || a.escaped != b.escaped)
            return false;
        a.popFront();
        b.popFront();
    }
    return true;
}

private bool decodedPrefix(QueryText prefix, QueryText text)
    @safe pure nothrow @nogc
{
    if (prefix.decodedLength > text.decodedLength)
        return false;
    auto a = prefix.cursor();
    auto b = text.cursor();
    while (!a.empty)
    {
        if (b.empty || a.front != b.front)
            return false;
        a.popFront();
        b.popFront();
    }
    return true;
}

private bool decodedIsAscii(QueryText text) @safe pure nothrow @nogc
{
    auto input = text.cursor();
    while (!input.empty)
    {
        if (input.front >= 0x80)
            return false;
        input.popFront();
    }
    return true;
}

private char asciiLower(char value) @safe pure nothrow @nogc
    => value >= 'A' && value <= 'Z' ? cast(char)(value + ('a' - 'A')) : value;

private bool isAsciiLetter(ubyte value) @safe pure nothrow @nogc
    => (value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z');

private bool isAsciiSpace(char value) @safe pure nothrow @nogc
    => value == ' ' || value == '\t' || value == '\r'
        || value == '\n' || value == '\v' || value == '\f';

@("fuzzy.query.grammarAndEscapes")
@safe pure nothrow @nogc
unittest
{
    assert(decodedEscapedAt(QueryText(`\*`), 0));
    assert(!decodedContainsUnescapedMeta(QueryText(`\*`)));
    auto parsed = parseQuery(
        `foo "two words" ext:rs !*.md path:"src/lib" git:ignored \* :oops`);
    assert(parsed.hasValue);
    assert(parsed.value.fuzzyParts.length == 4);
    assert(parsed.value.fuzzyParts[0].raw == "foo");
    assert(parsed.value.fuzzyParts[1].raw == `"two words"`);
    assert(parsed.value.fuzzyParts[2].raw == `\*`);
    assert(parsed.value.fuzzyParts[3].raw == ":oops");
    assert(parsed.value.constraints.length == 4);
    assert(parsed.value.constraints[0].kind == ConstraintKind.extension);
    assert(parsed.value.constraints[1].negated);
    assert(parsed.value.constraints[3].status == GitStatus.ignored);

    char[32] decoded = void;
    auto escaped = parsed.value.fuzzyParts[2].decodeInto(decoded);
    assert(decoded[0 .. escaped.value] == "*");
}

@("fuzzy.query.locationsAndErrors")
@safe pure nothrow @nogc
unittest
{
    auto parsed = parseQuery(`src/app.d:120:7`);
    assert(parsed.hasValue);
    assert(parsed.value.location.startLine == 120);
    assert(parsed.value.location.startColumn == 7);
    assert(parsed.value.fuzzyParts[0].decodedLength == "src/app.d".length);

    auto range = parseQuery(`f:12:4-14:20`);
    assert(range.hasValue && range.value.location.hasEnd);
    assert(range.value.location.startLine == 12
        && range.value.location.startColumn == 4
        && range.value.location.endLine == 14
        && range.value.location.endColumn == 20);

    // Earliest-colon-wins survives the bounded candidate window: colons whose
    // tails hold more separators than any location grammar admits are
    // guaranteed failures, so skipping all but the last few changes nothing.
    auto manyColons = parseQuery(`a:1:2:3:4:5`);
    assert(manyColons.hasValue);
    assert(manyColons.value.location.startLine == 4
        && manyColons.value.location.startColumn == 5);
    assert(manyColons.value.fuzzyParts[0].decodedLength
        == "a:1:2:3".length);

    assert(parseQuery(`git:`).error.code == FuzzyErrorCode.emptyValue);
    assert(parseQuery(`git:m`).hasValue);
    assert(parseQuery(`type:source`).error.code == FuzzyErrorCode.unknownValue);
    assert(parseQuery(`"unterminated`).error.code == FuzzyErrorCode.unexpectedEnd);

    QueryParseOptions windows;
    windows.pathFlavor = PathFlavor.windows;
    auto drive = parseQuery("C:12", windows);
    assert(drive.hasValue && !drive.value.location.present);
    auto driveLocation = parseQuery("C:/src/app.d:12", windows);
    assert(driveLocation.hasValue
        && driveLocation.value.location.startLine == 12);
}

@("fuzzy.query.droppedPartDiagnosticsUseAnalyzedUnits")
@safe pure nothrow @nogc
unittest
{
    auto parsed = parseQuery("a é long");
    assert(parsed.hasValue);
    assert(parsed.value.diagnostics.droppedParts == 2);
}

@("fuzzy.query.extensionNegationUsesAnd")
@safe pure nothrow @nogc
unittest
{
    auto parsed = parseQuery(`!*.rs !*.md foo`);
    assert(parsed.hasValue);
    ConstraintWorkspace!() workspace;
    CandidateView candidate;
    candidate.path = "src/main.rs";
    candidate.filenameOffset = 4;
    assert(!evaluateConstraints(parsed.value, candidate, workspace).value);
    candidate.path = "src/main.d";
    assert(evaluateConstraints(parsed.value, candidate, workspace).value);
}

@("fuzzy.query.constraintRowsAndPositiveExtensionBucket")
@safe pure nothrow @nogc
unittest
{
    auto parsed = parseQuery(
        `ext:d ext:md path:src/app.d seg:src glob:**/*.d status:st`);
    assert(parsed.hasValue && parsed.value.constraints.length == 6);
    ConstraintWorkspace!() workspace;
    CandidateView candidate;
    candidate.path = "src/app.d";
    candidate.filenameOffset = 4;
    candidate.gitStatus = GitStatus.staged;
    assert(evaluateConstraints(parsed.value, candidate, workspace).value);
    candidate.path = "other/app.d";
    candidate.filenameOffset = 6;
    assert(!evaluateConstraints(parsed.value, candidate, workspace).value);

    auto escapedSpace = parseQuery(`two\ words`);
    assert(escapedSpace.hasValue
        && escapedSpace.value.fuzzyParts.length == 1);
    char[16] decoded = void;
    auto length = escapedSpace.value.fuzzyParts[0].decodeInto(decoded);
    assert(decoded[0 .. length.value] == "two words");
    assert(parseQuery(`glob:{a,}`).error.code
        == FuzzyErrorCode.malformedGlob);
}

@("fuzzy.query.globEscapesSurviveTokenDecoding")
@safe pure nothrow @nogc
unittest
{
    auto parsed = parseQuery(`glob:literal/\*.d`);
    assert(parsed.hasValue);
    ConstraintWorkspace!() workspace;
    CandidateView candidate;
    candidate.path = "literal/*.d";
    candidate.filenameOffset = 8;
    assert(evaluateConstraints(parsed.value, candidate, workspace).value);
    candidate.path = "literal/main.d";
    assert(!evaluateConstraints(parsed.value, candidate, workspace).value);
}

@("fuzzy.query.refinementCannotGrowTypoBudget")
@safe pure nothrow @nogc
unittest
{
    auto oldQuery = parseQuery("abcdefghijk");
    auto grownBudget = parseQuery("abcdefghijkl");
    assert(oldQuery.hasValue && grownBudget.hasValue);
    assert(!grownBudget.value.refines(oldQuery.value));

    auto stable = parseQuery("abcdefghi");
    auto narrower = parseQuery("abcdefghij");
    assert(stable.hasValue && narrower.hasValue);
    assert(narrower.value.refines(stable.value));

    auto changedConstraint = parseQuery("abcdefghi ext:d");
    assert(!changedConstraint.value.refines(stable.value));

    auto literalGlob = parseQuery(`glob:\* abcdefghi`);
    auto wildcardGlob = parseQuery(`glob:* abcdefghij`);
    assert(!wildcardGlob.value.refines(literalGlob.value));
}

@("fuzzy.query.publicValuesAreValidated")
@safe pure nothrow @nogc
unittest
{
    auto options = QueryParseOptions.init;
    options.profile.kind = cast(AnalysisProfileKind) ubyte.max;
    assert(parseQuery("abc", options).error.code
        == FuzzyErrorCode.invalidConfiguration);
    options = QueryParseOptions.init;
    options.pathFlavor = cast(PathFlavor) ubyte.max;
    assert(parseQuery("abc", options).error.code
        == FuzzyErrorCode.invalidConfiguration);

    QueryText invalid = QueryText("abc", size_t.max, size_t.max);
    assert(invalid.decodedLength == 0 && invalid.cursor.empty);
    assert(invalid.dropFront(1).skipFront == size_t.max);

    auto query = parseQuery("ext:d");
    CandidateView candidate;
    candidate.path = "a.d";
    candidate.filenameOffset = size_t.max;
    ConstraintWorkspace!() workspace;
    assert(evaluateConstraints(query.value, candidate, workspace).error.code
        == FuzzyErrorCode.invalidCandidate);
}

@("fuzzy.query.bench.parseAndAnalyze")
@benchmark @safe
unittest
{
    import sparkles.test_runner.bench : benchIter, blackBox;

    class Context
    {
        bool alternate;
    }
    auto context = new Context;
    benchIter({
        context.alternate = !context.alternate;
        const source = context.alternate
            ? `src controller ext:d !glob:**/generated/** git:m`
            : `src controller ext:d !glob:**/vendor/** git:m`;
        auto parsed = parseQuery(blackBox(source));
        assert(parsed.hasValue);
        blackBox(parsed.value.diagnostics.droppedParts);
    }, ["profile": "codePath", "tier": "parse+analyze+glob-compile",
        "construction": "included", "corpus": "interactive-query"]);
}
