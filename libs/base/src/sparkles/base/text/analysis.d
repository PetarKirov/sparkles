/**
Bounded Unicode text analysis for allocation-free search and indexing.

The analyzer decodes well-formed UTF-8 scalars and preserves each malformed
byte as an opaque unit, applies generated Unicode 17 normalization and folding
tables, retains source-byte provenance, and optionally marks Unicode word
boundaries and removes caller-supplied stopwords. All storage is embedded in a
caller-owned `AnalysisWorkspace`.
*/
module sparkles.base.text.analysis;

import sparkles.base.text.unicode_tables : canonicalCombiningClass,
    canonicalComposition,
    canonicalDecomposition, canonicalDecompositionValue, fullCaseFold,
    fullCaseFoldValue, compatibilityDecomposition,
    compatibilityDecompositionValue, isUnicodeMark, isUnicodeUppercase,
    simpleCaseFold, wordBreakClass, UnicodeMappingSpan, WordBreakClass;
import sparkles.base.text.utf : decodeFirstUtf8;
import sparkles.base.text.utf8 : utf8SequenceLength;

/// Values above the Unicode scalar range encode one malformed source byte.
enum uint opaqueByteBase = 0x11_0000;

/// Normalization form used by an analysis profile.
enum AnalysisNormalization : ubyte
{
    /// Canonical decomposition followed by canonical composition.
    nfc,
    /// Compatibility decomposition followed by canonical composition.
    nfkc,
}

/// Case transformation used by an analysis profile.
enum AnalysisCase : ubyte
{
    sensitive,
    simpleFold,
    fullFold,
}

/// Per-unit facts retained from the source and analysis pipeline.
enum TextUnitFlags : ushort
{
    none = 0,
    /// The unit represents one malformed UTF-8 byte.
    opaque = 1 << 0,
    /// At least one source scalar contributing to this unit was uppercase.
    sourceUppercase = 1 << 1,
    /// This unit begins a Unicode word after analysis.
    wordStart = 1 << 2,
}

/// One analyzed scalar-like value and its original source byte range.
struct TextUnit
{
    uint value;
    uint sourceStart;
    uint sourceEnd;
    TextUnitFlags flags;

    /// Whether this unit represents a malformed byte rather than Unicode.
    bool isOpaque() const @safe pure nothrow @nogc
        => (flags & TextUnitFlags.opaque) != 0;

    /// Whether the source contributing to this unit contained uppercase text.
    bool sourceWasUppercase() const @safe pure nothrow @nogc
        => (flags & TextUnitFlags.sourceUppercase) != 0;

    /// Whether a Unicode word begins at this unit.
    bool startsWord() const @safe pure nothrow @nogc
        => (flags & TextUnitFlags.wordStart) != 0;
}

/// One already-analyzed stopword. Storage is owned by the caller.
struct Stopword
{
    const(uint)[] units;
}

/// Immutable caller-owned stopword vocabulary. The empty value removes none.
struct StopwordLexicon
{
    const(Stopword)[] words;
}

/// Runtime analysis policy. `codePath` and `generalLanguage` are constructors.
struct AnalysisOptions
{
    AnalysisNormalization normalization = AnalysisNormalization.nfc;
    AnalysisCase caseMode = AnalysisCase.sensitive;
    bool stripMarks;
    bool markWords;
    StopwordLexicon stopwords;

    /// NFC code/path analysis. `caseMode` is selected by the query's smart-case
    /// probe (`sensitive` or `simpleFold`).
    static AnalysisOptions codePath(AnalysisCase caseMode = AnalysisCase.simpleFold)
        @safe pure nothrow @nogc
    {
        AnalysisOptions result;
        result.caseMode = caseMode;
        return result;
    }

    /// NFKC/full-fold/accent-stripping natural-language analysis.
    static AnalysisOptions generalLanguage(StopwordLexicon stopwords = StopwordLexicon.init)
        @safe pure nothrow @nogc
    {
        AnalysisOptions result;
        result.normalization = AnalysisNormalization.nfkc;
        result.caseMode = AnalysisCase.fullFold;
        result.stripMarks = true;
        result.markWords = true;
        result.stopwords = stopwords;
        return result;
    }
}

/// Why bounded analysis did not produce a complete unit sequence.
enum AnalysisError : ubyte
{
    none,
    invalidOptions,
    sourceTooLong,
    outputFull,
    segmentTooLong,
}

/// Result of one analysis operation.
struct AnalysisResult
{
    AnalysisError error;
    size_t length;
    size_t sourceOffset;
    bool containsUppercase;

    bool succeeded() const @safe pure nothrow @nogc
        => error == AnalysisError.none;
}

private struct SegmentUnit
{
    TextUnit unit;
    ubyte canonicalClass;
}

/**
Fixed storage for one analyzed text.

`MaxUnits` is the complete output capacity. `MaxSegmentUnits` bounds one
starter plus its combining sequence; Unicode permits arbitrarily long
sequences, so exceeding it is an explicit `segmentTooLong` result.
*/
struct AnalysisWorkspace(size_t MaxUnits, size_t MaxSegmentUnits = 64)
if (MaxUnits > 0 && MaxSegmentUnits > 0)
{
    TextUnit[MaxUnits] units = void;
    private SegmentUnit[MaxSegmentUnits] segment = void;
    private size_t length_;
    private size_t segmentLength_;

    /// Complete analyzed output after a successful call.
    const(TextUnit)[] output() const return scope @safe pure nothrow @nogc
        => units[0 .. length_];

    /// Mutable output for callers that add domain-specific boundary flags.
    TextUnit[] mutableOutput() return scope @safe pure nothrow @nogc
        => units[0 .. length_];

    /// Number of complete units currently stored.
    size_t length() const @safe pure nothrow @nogc => length_;
}

/**
Analyze `source` into `workspace` under `options`.

Malformed UTF-8 is accepted byte-for-byte as opaque units. On failure the
workspace contains only a prefix and must not be consumed; the next call resets
it. Complexity is `O(source bytes + emitted units * MaxSegmentUnits)` due to
bounded canonical-order insertion, with no allocation.
*/
AnalysisResult analyzeText(size_t MaxUnits, size_t MaxSegmentUnits)(
    scope const(char)[] source, in AnalysisOptions options,
    ref AnalysisWorkspace!(MaxUnits, MaxSegmentUnits) workspace)
    @safe pure nothrow @nogc
{
    workspace.length_ = 0;
    workspace.segmentLength_ = 0;

    AnalysisResult result;
    if ((options.normalization != AnalysisNormalization.nfc
            && options.normalization != AnalysisNormalization.nfkc)
        || (options.caseMode != AnalysisCase.sensitive
            && options.caseMode != AnalysisCase.simpleFold
            && options.caseMode != AnalysisCase.fullFold))
    {
        result.error = AnalysisError.invalidOptions;
        return result;
    }
    if (source.length > uint.max)
    {
        result.error = AnalysisError.sourceTooLong;
        return result;
    }

    size_t offset;
    while (offset < source.length)
    {
        const start = offset;
        const first = cast(ubyte) source[offset];
        if (first < 0x80)
        {
            ++offset;
            const cp = cast(dchar) first;
            if (isUnicodeUppercase(cp))
                result.containsUppercase = true;
            if (!appendSourceScalar(cp, cast(uint) start, cast(uint) offset,
                    isUnicodeUppercase(cp), options, workspace, result))
                return finishFailure(workspace, result, start);
            continue;
        }

        const sequenceLength = utf8SequenceLength(source, offset);
        if (sequenceLength == 0)
        {
            ++offset;
            if (!appendOpaque(first, cast(uint) start, cast(uint) offset,
                    workspace, result))
                return finishFailure(workspace, result, start);
            continue;
        }

        const cp = decodeFirstUtf8(source[offset .. offset + sequenceLength]);
        offset += sequenceLength;
        const uppercase = isUnicodeUppercase(cp);
        if (uppercase)
            result.containsUppercase = true;
        if (!appendSourceScalar(cp, cast(uint) start, cast(uint) offset,
                uppercase, options, workspace, result))
            return finishFailure(workspace, result, start);
    }

    if (!flushSegment(workspace, result))
        return finishFailure(workspace, result, source.length);

    if (options.markWords || options.stopwords.words.length)
        markWordBoundaries(workspace);
    if (options.stopwords.words.length)
        removeStopwords(options.stopwords, workspace);

    result.length = workspace.length_;
    return result;
}

@("text.analysis.normalizationAndProvenance")
@safe pure nothrow @nogc
unittest
{
    AnalysisWorkspace!(32, 16) workspace;
    auto result = analyzeText("A\u0308ffin", AnalysisOptions.codePath(), workspace);
    assert(result.succeeded);
    assert(workspace.output.length == 5);
    assert(workspace.output[0].value == simpleCaseFold('Ä'));
    assert(workspace.output[0].sourceStart == 0);
    assert(workspace.output[0].sourceEnd == 3);

    result = analyzeText("Straße", AnalysisOptions.generalLanguage(), workspace);
    assert(result.succeeded);
    static immutable uint[] expected = ['s', 't', 'r', 'a', 's', 's', 'e'];
    assert(workspace.output.length == expected.length);
    foreach (i, unit; workspace.output)
        assert(unit.value == expected[i]);
}

@("text.analysis.invalidUtf8IsOpaque")
@safe pure nothrow @nogc
unittest
{
    AnalysisWorkspace!(8, 8) workspace;
    auto result = analyzeText("a\xFF\x80b", AnalysisOptions.codePath(), workspace);
    assert(result.succeeded);
    assert(workspace.output.length == 4);
    assert(workspace.output[1].value == opaqueByteBase + 0xFF);
    assert(workspace.output[2].value == opaqueByteBase + 0x80);
    assert(workspace.output[1].sourceStart == 1);
    assert(workspace.output[1].sourceEnd == 2);
}

@("text.analysis.capacityIsExplicit")
@safe pure nothrow @nogc
unittest
{
    AnalysisWorkspace!(2, 8) workspace;
    auto result = analyzeText("abc", AnalysisOptions.codePath(), workspace);
    assert(result.error == AnalysisError.outputFull);
    assert(result.sourceOffset == 2);
}

@("text.analysis.canonicalOrderHangulAndCompatibility")
@safe pure nothrow @nogc
unittest
{
    AnalysisWorkspace!(16, 8) workspace;
    auto result = analyzeText("A\u0315\u0300",
        AnalysisOptions.codePath(AnalysisCase.sensitive), workspace);
    assert(result.succeeded && workspace.output.length == 2);
    assert(workspace.output[0].value == 0x00C0);
    assert(workspace.output[1].value == 0x0315);
    assert(workspace.output[0].sourceStart == 0
        && workspace.output[0].sourceEnd == 5);

    result = analyzeText("\u1100\u1161",
        AnalysisOptions.codePath(AnalysisCase.sensitive), workspace);
    assert(result.succeeded && workspace.output.length == 1);
    assert(workspace.output[0].value == 0xAC00);

    result = analyzeText("\uFB01 \u0130",
        AnalysisOptions.generalLanguage(), workspace);
    assert(result.succeeded);
    static immutable uint[] expected = ['f', 'i', ' ', 'i'];
    assert(workspace.output.length == expected.length);
    foreach (i, unit; workspace.output)
        assert(unit.value == expected[i]);
}

@("text.analysis.normalizationSegmentBoundIsExplicit")
@safe pure nothrow @nogc
unittest
{
    AnalysisWorkspace!(8, 2) workspace;
    auto result = analyzeText("a\u0300\u0315",
        AnalysisOptions.codePath(), workspace);
    assert(result.error == AnalysisError.segmentTooLong);
}

@("text.analysis.invalidOptionsAreValues")
@safe pure nothrow @nogc
unittest
{
    AnalysisWorkspace!(8, 8) workspace;
    auto options = AnalysisOptions.init;
    options.caseMode = cast(AnalysisCase) ubyte.max;
    auto result = analyzeText("abc", options, workspace);
    assert(result.error == AnalysisError.invalidOptions);

    options = AnalysisOptions.init;
    options.normalization = cast(AnalysisNormalization) ubyte.max;
    result = analyzeText("abc", options, workspace);
    assert(result.error == AnalysisError.invalidOptions);
}

private AnalysisResult finishFailure(size_t MaxUnits, size_t MaxSegmentUnits)(
    ref AnalysisWorkspace!(MaxUnits, MaxSegmentUnits) workspace,
    AnalysisResult result, size_t sourceOffset) @safe pure nothrow @nogc
{
    result.length = workspace.length_;
    result.sourceOffset = result.error == AnalysisError.outputFull
            && workspace.segmentLength_ != 0
        ? workspace.segment[0].unit.sourceStart : sourceOffset;
    return result;
}

private bool appendOpaque(size_t MaxUnits, size_t MaxSegmentUnits)(ubyte value,
    uint start, uint end, ref AnalysisWorkspace!(MaxUnits, MaxSegmentUnits) workspace,
    ref AnalysisResult result) @safe pure nothrow @nogc
{
    if (!flushSegment(workspace, result))
        return false;
    if (workspace.length_ == MaxUnits)
    {
        result.error = AnalysisError.outputFull;
        return false;
    }
    workspace.units[workspace.length_++] = TextUnit(
        opaqueByteBase + value, start, end, TextUnitFlags.opaque);
    return true;
}

private bool appendSourceScalar(size_t MaxUnits, size_t MaxSegmentUnits)(dchar cp,
    uint start, uint end, bool uppercase, in AnalysisOptions options,
    ref AnalysisWorkspace!(MaxUnits, MaxSegmentUnits) workspace,
    ref AnalysisResult result) @safe pure nothrow @nogc
{
    TextUnitFlags flags;
    if (uppercase)
        flags |= TextUnitFlags.sourceUppercase;

    return forEachDecomposed(cp, options.normalization, (dchar decomposed) {
        final switch (options.caseMode)
        {
        case AnalysisCase.sensitive:
            return appendFoldedScalar(decomposed, start, end, flags,
                options, workspace, result);
        case AnalysisCase.simpleFold:
            return appendFoldedScalar(simpleCaseFold(decomposed), start, end,
                flags, options, workspace, result);
        case AnalysisCase.fullFold:
            const folded = fullCaseFold(decomposed);
            if (folded.length == 0)
                return appendFoldedScalar(decomposed, start, end, flags,
                    options, workspace, result);
            foreach (i; 0 .. folded.length)
            {
                if (!appendFoldedScalar(fullCaseFoldValue(folded.offset + i),
                        start, end, flags, options, workspace, result))
                    return false;
            }
            return true;
        }
    });
}

private bool appendFoldedScalar(size_t MaxUnits, size_t MaxSegmentUnits)(dchar cp,
    uint start, uint end, TextUnitFlags flags, in AnalysisOptions options,
    ref AnalysisWorkspace!(MaxUnits, MaxSegmentUnits) workspace,
    ref AnalysisResult result) @safe pure nothrow @nogc
{
    // Folding can itself introduce a decomposable scalar. Re-decompose once;
    // the generated mappings are already recursively expanded.
    return forEachDecomposed(cp, options.normalization, (dchar value) {
        if (options.stripMarks && isUnicodeMark(value))
            return true;
        return appendNormalizedUnit(
            TextUnit(value, start, end, flags), workspace, result);
    });
}

private bool forEachDecomposed(alias consume)(dchar cp,
    AnalysisNormalization normalization, scope consume sink)
    @safe pure nothrow @nogc
{
    if (isHangulSyllable(cp))
    {
        dchar[3] parts;
        const count = decomposeHangul(cp, parts);
        foreach (i; 0 .. count)
            if (!sink(parts[i]))
                return false;
        return true;
    }

    UnicodeMappingSpan mapping;
    final switch (normalization)
    {
    case AnalysisNormalization.nfc:
        mapping = canonicalDecomposition(cp);
        break;
    case AnalysisNormalization.nfkc:
        mapping = compatibilityDecomposition(cp);
        break;
    }
    if (mapping.length == 0)
        return sink(cp);
    foreach (i; 0 .. mapping.length)
    {
        const value = normalization == AnalysisNormalization.nfc
            ? canonicalDecompositionValue(mapping.offset + i)
            : compatibilityDecompositionValue(mapping.offset + i);
        if (!sink(value))
            return false;
    }
    return true;
}

private bool appendNormalizedUnit(size_t MaxUnits, size_t MaxSegmentUnits)(
    TextUnit unit,
    ref AnalysisWorkspace!(MaxUnits, MaxSegmentUnits) workspace,
    ref AnalysisResult result) @safe pure nothrow @nogc
{
    const canonicalClass = canonicalCombiningClass(cast(dchar) unit.value);
    if (canonicalClass == 0 && workspace.segmentLength_ != 0)
    {
        // Hangul is the only composition between adjacent class-zero units.
        if (workspace.segmentLength_ == 1)
        {
            const composed = composeHangul(
                cast(dchar) workspace.segment[0].unit.value,
                cast(dchar) unit.value);
            if (composed != dchar.init)
            {
                ref target = workspace.segment[0].unit;
                target.value = composed;
                mergeProvenance(target, unit);
                return true;
            }
        }
        if (!flushSegment(workspace, result))
            return false;
    }
    if (workspace.segmentLength_ == MaxSegmentUnits)
    {
        result.error = AnalysisError.segmentTooLong;
        return false;
    }

    size_t at = workspace.segmentLength_;
    if (canonicalClass != 0)
    {
        while (at > 0
            && workspace.segment[at - 1].canonicalClass > canonicalClass
            && workspace.segment[at - 1].canonicalClass != 0)
        {
            workspace.segment[at] = workspace.segment[at - 1];
            --at;
        }
    }
    workspace.segment[at] = SegmentUnit(unit, canonicalClass);
    ++workspace.segmentLength_;
    return true;
}

// Deliberately options-free: canonical composition applies identically after
// NFC and NFKC decomposition, so segment flushing cannot depend on the
// analysis profile. An options-sensitive change here must re-add the
// parameter and revisit every call site (including the opaque-byte path).
private bool flushSegment(size_t MaxUnits, size_t MaxSegmentUnits)(
    ref AnalysisWorkspace!(MaxUnits, MaxSegmentUnits) workspace,
    ref AnalysisResult result) @safe pure nothrow @nogc
{
    if (workspace.segmentLength_ == 0)
        return true;

    size_t starter = size_t.max;
    ubyte lastClass;
    size_t write;
    foreach (read; 0 .. workspace.segmentLength_)
    {
        auto current = workspace.segment[read];
        if (current.canonicalClass == 0)
        {
            starter = write;
            lastClass = 0;
            workspace.segment[write++] = current;
            continue;
        }

        if (starter != size_t.max
            && (lastClass == 0 || lastClass < current.canonicalClass))
        {
            const composed = canonicalComposition(
                cast(dchar) workspace.segment[starter].unit.value,
                cast(dchar) current.unit.value);
            if (composed != dchar.init)
            {
                workspace.segment[starter].unit.value = composed;
                mergeProvenance(workspace.segment[starter].unit, current.unit);
                continue;
            }
        }
        lastClass = current.canonicalClass;
        workspace.segment[write++] = current;
    }

    if (write > MaxUnits - workspace.length_)
    {
        result.error = AnalysisError.outputFull;
        return false;
    }
    foreach (i; 0 .. write)
        workspace.units[workspace.length_++] = workspace.segment[i].unit;
    workspace.segmentLength_ = 0;
    return true;
}

private void mergeProvenance(ref TextUnit target, in TextUnit source)
    @safe pure nothrow @nogc
{
    if (source.sourceStart < target.sourceStart)
        target.sourceStart = source.sourceStart;
    if (source.sourceEnd > target.sourceEnd)
        target.sourceEnd = source.sourceEnd;
    target.flags |= source.flags;
}

private enum dchar hangulSBase = 0xAC00;
private enum dchar hangulLBase = 0x1100;
private enum dchar hangulVBase = 0x1161;
private enum dchar hangulTBase = 0x11A7;
private enum int hangulLCount = 19;
private enum int hangulVCount = 21;
private enum int hangulTCount = 28;
private enum int hangulNCount = hangulVCount * hangulTCount;
private enum int hangulSCount = hangulLCount * hangulNCount;

private bool isHangulSyllable(dchar cp) @safe pure nothrow @nogc
    => cp >= hangulSBase && cp < hangulSBase + hangulSCount;

private ubyte decomposeHangul(dchar cp, ref dchar[3] output)
    @safe pure nothrow @nogc
{
    const index = cast(int) cp - hangulSBase;
    output[0] = hangulLBase + index / hangulNCount;
    output[1] = hangulVBase + (index % hangulNCount) / hangulTCount;
    const trailing = index % hangulTCount;
    if (trailing != 0)
    {
        output[2] = hangulTBase + trailing;
        return 3;
    }
    return 2;
}

private dchar composeHangul(dchar first, dchar second)
    @safe pure nothrow @nogc
{
    if (first >= hangulLBase && first < hangulLBase + hangulLCount
        && second >= hangulVBase && second < hangulVBase + hangulVCount)
    {
        return hangulSBase
            + (first - hangulLBase) * hangulNCount
            + (second - hangulVBase) * hangulTCount;
    }
    const syllableIndex = cast(int) first - hangulSBase;
    if (syllableIndex >= 0 && syllableIndex < hangulSCount
        && syllableIndex % hangulTCount == 0
        && second > hangulTBase && second < hangulTBase + hangulTCount)
    {
        return first + second - hangulTBase;
    }
    return dchar.init;
}

private bool isIgnoredWordClass(WordBreakClass kind) @safe pure nothrow @nogc
    => kind == WordBreakClass.extend || kind == WordBreakClass.format
        || kind == WordBreakClass.zwj;

private bool isLetter(WordBreakClass kind) @safe pure nothrow @nogc
    => kind == WordBreakClass.aLetter || kind == WordBreakClass.hebrewLetter;

private bool isWordCore(WordBreakClass kind) @safe pure nothrow @nogc
    => isLetter(kind) || kind == WordBreakClass.numeric
        || kind == WordBreakClass.katakana
        || kind == WordBreakClass.extendNumLet;

private void markWordBoundaries(size_t MaxUnits, size_t MaxSegmentUnits)(
    ref AnalysisWorkspace!(MaxUnits, MaxSegmentUnits) workspace)
    @safe pure nothrow @nogc
{
    foreach (ref unit; workspace.units[0 .. workspace.length_])
        unit.flags &= ~TextUnitFlags.wordStart;
    foreach (i; 0 .. workspace.length_)
    {
        const kind = unitWordClass(workspace.units[i]);
        if (!isWordCore(kind))
            continue;
        if (i == 0 || isWordBoundaryBefore(i, workspace))
            workspace.units[i].flags |= TextUnitFlags.wordStart;
    }
}

private bool isWordBoundaryBefore(size_t MaxUnits, size_t MaxSegmentUnits)(
    size_t at, ref AnalysisWorkspace!(MaxUnits, MaxSegmentUnits) workspace)
    @safe pure nothrow @nogc
{
    const current = unitWordClass(workspace.units[at]);
    size_t prev = at;
    while (prev > 0)
    {
        --prev;
        if (!isIgnoredWordClass(unitWordClass(workspace.units[prev])))
            break;
    }
    if (prev == at || (prev == 0
            && isIgnoredWordClass(unitWordClass(workspace.units[prev]))))
        return true;
    const before = unitWordClass(workspace.units[prev]);

    if (before == WordBreakClass.cr && current == WordBreakClass.lf)
        return false;
    if (before == WordBreakClass.cr || before == WordBreakClass.lf
        || before == WordBreakClass.newline || current == WordBreakClass.cr
        || current == WordBreakClass.lf || current == WordBreakClass.newline)
        return true;
    if (isLetter(before) && (isLetter(current)
            || current == WordBreakClass.numeric))
        return false;
    if (before == WordBreakClass.numeric
        && (isLetter(current) || current == WordBreakClass.numeric))
        return false;
    if (before == WordBreakClass.katakana && current == WordBreakClass.katakana)
        return false;
    if ((isWordCore(before) && current == WordBreakClass.extendNumLet)
        || (before == WordBreakClass.extendNumLet && isWordCore(current)))
        return false;

    // UAX #29 sandwich rules: AHLetter × MidLetter × AHLetter and the numeric
    // counterpart. The punctuation itself does not start a word; when arriving
    // at the right core, look through it to the preceding core.
    if (before == WordBreakClass.midLetter
        || before == WordBreakClass.midNumLet
        || before == WordBreakClass.singleQuote
        || before == WordBreakClass.midNum)
    {
        size_t left = prev;
        while (left > 0)
        {
            --left;
            const leftKind = unitWordClass(workspace.units[left]);
            if (isIgnoredWordClass(leftKind))
                continue;
            if (isLetter(leftKind) && isLetter(current)
                && before != WordBreakClass.midNum)
                return false;
            if (leftKind == WordBreakClass.numeric
                && current == WordBreakClass.numeric
                && before != WordBreakClass.midLetter)
                return false;
            break;
        }
    }
    return true;
}

private WordBreakClass unitWordClass(in TextUnit unit)
    @safe pure nothrow @nogc
{
    return unit.isOpaque ? WordBreakClass.other
        : wordBreakClass(cast(dchar) unit.value);
}

private void removeStopwords(size_t MaxUnits, size_t MaxSegmentUnits)(
    in StopwordLexicon lexicon,
    ref AnalysisWorkspace!(MaxUnits, MaxSegmentUnits) workspace)
    @safe pure nothrow @nogc
{
    size_t read;
    size_t write;
    while (read < workspace.length_)
    {
        const kind = unitWordClass(workspace.units[read]);
        if (!isWordCore(kind))
        {
            workspace.units[write++] = workspace.units[read++];
            continue;
        }
        const start = read;
        ++read;
        while (read < workspace.length_
            && !workspace.units[read].startsWord
            && (isWordCore(unitWordClass(workspace.units[read]))
                || isIgnoredWordClass(unitWordClass(workspace.units[read]))))
            ++read;
        if (isStopword(workspace.units[start .. read], lexicon))
            continue;
        foreach (i; start .. read)
            workspace.units[write++] = workspace.units[i];
    }
    workspace.length_ = write;
}

private bool isStopword(scope const(TextUnit)[] units,
    in StopwordLexicon lexicon) @safe pure nothrow @nogc
{
    foreach (word; lexicon.words)
    {
        if (word.units.length != units.length)
            continue;
        bool equal = true;
        foreach (i, value; word.units)
        {
            if (units[i].value != value)
            {
                equal = false;
                break;
            }
        }
        if (equal)
            return true;
    }
    return false;
}
