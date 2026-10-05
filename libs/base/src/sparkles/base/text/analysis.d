/**
Caller-owned Unicode analysis for search and indexing.

The pipeline uses the owned UTF, normalization, casing and word-boundary cores.
Malformed UTF-8 bytes remain opaque barriers. Each output retains an exact set
of contributing source spans; its byte range is only the enclosing envelope.
*/
module sparkles.base.text.analysis;

import sparkles.base.text.unicode_tables : canonicalCombiningClass,
    canonicalDecomposition, canonicalDecompositionValue,
    compatibilityDecomposition, compatibilityDecompositionValue,
    isUnicodeMark, isUnicodeUppercase, simpleCaseFold, wordBreakClass,
    WordBreakClass;
import sparkles.base.text.utf : UtfMode, UtfToken, UtfTokenKind;
import sparkles.base.text.unicode_algorithm : UnicodeResult, UnicodeStatus,
    UnicodeSourceSpan, UnicodeBoundary, UnicodeBoundaryKind;
import sparkles.base.text.transform : UnicodeTransformUnit,
    UnicodeTransformEpoch, UnicodeTransformWorkspace, UnicodeTransformView,
    UnicodeDeletion, decodeTransformText;
import sparkles.base.text.normalization : UnicodeNormalization,
    UnicodeNormalizationItem, UnicodeNormalizationScratch, normalizeText;
import sparkles.base.text.casing : UnicodeCaseMode, UnicodeFoldMode,
    UnicodeCasingScratch, caseTransform;
import sparkles.base.text.boundaries : WordBoundaryWorkspace, wordBoundaries;

/// Values above the Unicode scalar range encode one malformed source byte.
enum uint opaqueByteBase = 0x11_0000;

/// Normalization form used by an analysis profile.
enum AnalysisNormalization : ubyte { nfc, nfkc, nfd, nfkd }

/// Case transformation used by an analysis profile.
enum AnalysisCase : ubyte { sensitive, simpleFold, fullFold, lower, upper, title }

/// Per-unit facts retained from the source and analysis pipeline.
enum TextUnitFlags : ushort
{
    none = 0,
    opaque = 1 << 0,
    sourceUppercase = 1 << 1,
    wordStart = 1 << 2,
}

/**
One analyzed value. sourceStart/sourceEnd enclose all contributors and can include
unrelated intervening bytes. Use contributingSourceSpans for exact highlighting.
Provenance indices belong to the workspace that produced this unit.
*/
struct TextUnit
{
    uint value;
    uint sourceStart;
    uint sourceEnd;
    TextUnitFlags flags;
    size_t provenanceStart;
    size_t provenanceCount;

    bool isOpaque() const @safe pure nothrow @nogc
        => (flags & TextUnitFlags.opaque) != 0;
    bool sourceWasUppercase() const @safe pure nothrow @nogc
        => (flags & TextUnitFlags.sourceUppercase) != 0;
    bool startsWord() const @safe pure nothrow @nogc
        => (flags & TextUnitFlags.wordStart) != 0;
}

/// One already-analyzed stopword. Storage is owned by the caller.
struct Stopword { const(uint)[] units; }

/// Caller-owned vocabulary and its caller-assigned content revision.
struct StopwordLexicon
{
    const(Stopword)[] words;
    ulong revision;
}

/**
Runtime analysis policy. Casing sees the normalized input's original context.
renormalize declares whether casing output is normalized again. Accent stripping
canonically decomposes, removes marks, then restores the requested form.
*/
struct AnalysisOptions
{
    AnalysisNormalization normalization = AnalysisNormalization.nfc;
    AnalysisCase caseMode = AnalysisCase.sensitive;
    bool stripMarks;
    bool markWords;
    StopwordLexicon stopwords;
    string locale;
    bool renormalize = true;
    UnicodeFoldMode foldMode = UnicodeFoldMode.defaultFold;

    static AnalysisOptions codePath(AnalysisCase caseMode = AnalysisCase.simpleFold)
        @safe pure nothrow @nogc
    {
        AnalysisOptions result;
        result.caseMode = caseMode;
        return result;
    }

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
    none, invalidOptions, sourceTooLong, outputFull, segmentTooLong,
    workspaceFull, unsupportedLocale,
}

struct AnalysisResult
{
    AnalysisError error;
    size_t length;
    size_t sourceOffset;
    bool containsUppercase;

    bool succeeded() const @safe pure nothrow @nogc
        => error == AnalysisError.none;
}

/**
MaxUnits bounds final output. MaxSegmentUnits bounds one decomposed starter and
its combining sequence. MaxWorkspaceUnits separately bounds intermediate units;
MaxProvenanceSpans bounds exact source sets and deletion records in each bank.
These are caller storage limits, not Unicode algorithm limits. Reusing this
workspace invalidates all earlier output and provenance borrows.
*/
struct AnalysisWorkspace(size_t MaxUnits, size_t MaxSegmentUnits = 64,
    size_t MaxWorkspaceUnits = MaxUnits + MaxSegmentUnits,
    size_t MaxProvenanceSpans = 4 * MaxWorkspaceUnits)
if (MaxUnits > 0 && MaxSegmentUnits > 0 && MaxWorkspaceUnits >= MaxUnits
    && MaxProvenanceSpans > 0)
{
    TextUnit[MaxUnits] units = void;
    private UnicodeTransformUnit[MaxWorkspaceUnits][2] transformUnits = void;
    private UnicodeSourceSpan[MaxProvenanceSpans][2] sourceSpans = void;
    private UnicodeDeletion[MaxProvenanceSpans][2] removed = void;
    private UnicodeTransformEpoch[1][2] epochs;
    private UnicodeNormalizationItem[MaxWorkspaceUnits] normalizationItems = void;
    private size_t[MaxSegmentUnits] ordering = void;
    private size_t[MaxWorkspaceUnits + 1] boundaryMap = void;
    private ubyte[MaxWorkspaceUnits] contexts = void;
    private UtfToken[MaxWorkspaceUnits] tokens = void;
    private UnicodeBoundary[MaxWorkspaceUnits + 1] boundaries = void;
    private WordBoundaryWorkspace[MaxWorkspaceUnits] wordWorkspace = void;
    private size_t length_;
    private size_t bank_;
    private size_t deletionCount_;

    const(TextUnit)[] output() scope return const @safe pure nothrow @nogc
        => units[0 .. length_];
    TextUnit[] mutableOutput() scope return @safe pure nothrow @nogc
        => units[0 .. length_];
    size_t length() const @safe pure nothrow @nogc => length_;

    /// Exact sorted, deduplicated contributor set; never the enclosing envelope.
    const(UnicodeSourceSpan)[] contributingSourceSpans(in TextUnit unit)
        scope return const @safe pure nothrow @nogc
    in (unit.provenanceStart <= MaxProvenanceSpans
        && unit.provenanceCount <= MaxProvenanceSpans - unit.provenanceStart)
        => sourceSpans[bank_][unit.provenanceStart ..
            unit.provenanceStart + unit.provenanceCount];

    /// Exact removed source spans anchored at analyzed output boundaries.
    const(UnicodeDeletion)[] deletions() scope return const @safe pure nothrow @nogc
        => removed[bank_][0 .. deletionCount_];

    private UnicodeTransformWorkspace bank(size_t index) scope return
        @safe pure nothrow @nogc
        => UnicodeTransformWorkspace(units: transformUnits[index][],
            spans: sourceSpans[index][], deletions: removed[index][],
            epoch: epochs[index][]);
}

/**
Analyze source with no allocation. Failure publishes no partial output. Opaque
bytes preserve their exact source position and terminate every Unicode context.
The cores are linear in decoded/decomposed output and provenance emitted.
*/
AnalysisResult analyzeText(size_t N, size_t S, size_t W, size_t P)(
    scope const(char)[] source, in AnalysisOptions options,
    ref AnalysisWorkspace!(N, S, W, P) workspace)
{
    workspace.length_ = workspace.deletionCount_ = 0;
    scope UnicodeTransformWorkspace[2] banks;
    banks[0] = workspace.bank(0);
    banks[1] = workspace.bank(1);
    foreach (ref bank; banks) bank.begin();
    AnalysisResult result;
    if (cast(uint) options.normalization > cast(uint) AnalysisNormalization.nfkd
        || cast(uint) options.caseMode > cast(uint) AnalysisCase.title
        || cast(uint) options.foldMode > cast(uint) UnicodeFoldMode.turkic)
        return AnalysisResult(error: AnalysisError.invalidOptions);
    if (options.locale != "" && options.locale != "tr"
        && options.locale != "az" && options.locale != "lt")
        return AnalysisResult(error: AnalysisError.unsupportedLocale);
    if (source.length > uint.max)
        return AnalysisResult(error: AnalysisError.sourceTooLong);
    auto status = decodeTransformText(source, UtfMode.opaque, banks[0]);
    if (!status.succeeded()) return analysisFailure(status, result);
    foreach (ref unit; banks[0].constructionUnits())
    {
        if (!unit.isOpaque() && isUnicodeUppercase(unit.value))
        {
            unit.flags |= TextUnitFlags.sourceUppercase;
            result.containsUppercase = true;
        }
    }
    const form = analysisForm(options.normalization);
    size_t current;
    auto segment = checkAnalysisSegments(banks[current].output(), form, S);
    if (!segment.succeeded()) return segment;
    auto normalization = UnicodeNormalizationScratch(items: workspace.normalizationItems[],
        ordering: workspace.ordering[], boundaries: workspace.boundaryMap[]);
    status = normalizeText(banks[current].output(), form, banks[1 - current], normalization);
    if (!status.succeeded()) return analysisFailure(status, result);
    current = 1 - current;
    if (options.caseMode != AnalysisCase.sensitive)
    {
        auto casing = UnicodeCasingScratch(contexts: workspace.contexts[],
            boundaryMap: workspace.boundaryMap[], tokens: workspace.tokens[],
            words: workspace.boundaries[], wordWorkspace: workspace.wordWorkspace[]);
        status = caseTransform(banks[current].output(), banks[1 - current],
            analysisCase(options.caseMode), casing, options.locale, options.foldMode);
        if (!status.succeeded()) return analysisFailure(status, result);
        current = 1 - current;
        if (options.renormalize)
        {
            segment = checkAnalysisSegments(banks[current].output(), form, S);
            if (!segment.succeeded()) return segment;
            status = normalizeText(banks[current].output(), form,
                banks[1 - current], normalization);
            if (!status.succeeded()) return analysisFailure(status, result);
            current = 1 - current;
        }
    }
    if (options.stripMarks)
    {
        segment = checkAnalysisSegments(banks[current].output(), UnicodeNormalization.NFD, S);
        if (!segment.succeeded()) return segment;
        status = normalizeText(banks[current].output(), UnicodeNormalization.NFD,
            banks[1 - current], normalization);
        if (!status.succeeded()) return analysisFailure(status, result);
        current = 1 - current;
        status = filterAnalysis(banks[current].output(), banks[1 - current],
            true, StopwordLexicon.init, workspace.boundaryMap[], workspace.boundaries[]);
        if (!status.succeeded()) return analysisFailure(status, result);
        current = 1 - current;
        status = normalizeText(banks[current].output(), form, banks[1 - current], normalization);
        if (!status.succeeded()) return analysisFailure(status, result);
        current = 1 - current;
    }
    if (options.stopwords.words.length)
    {
        status = analyzeWords(banks[current].output(), workspace.tokens[],
            workspace.boundaries[], workspace.wordWorkspace[]);
        if (!status.succeeded()) return analysisFailure(status, result);
        status = filterAnalysis(banks[current].output(), banks[1 - current],
            false, options.stopwords, workspace.boundaryMap[], workspace.boundaries[]);
        if (!status.succeeded()) return analysisFailure(status, result);
        current = 1 - current;
    }
    const view = banks[current].output();
    if (view.units.length > N)
        return AnalysisResult(error: AnalysisError.outputFull,
            sourceOffset: view.contributingSourceSpans(N)[0].start,
            containsUppercase: result.containsUppercase);
    if (options.markWords || options.stopwords.words.length)
    {
        status = analyzeWords(view, workspace.tokens[], workspace.boundaries[],
            workspace.wordWorkspace[]);
        if (!status.succeeded()) return analysisFailure(status, result);
    }
    foreach (i, unit; view.units)
    {
        const spans = view.contributingSourceSpans(i);
        auto flags = cast(TextUnitFlags) unit.flags;
        if (unit.isOpaque()) flags |= TextUnitFlags.opaque;
        if ((options.markWords || options.stopwords.words.length)
            && workspace.boundaries[i].kind != UnicodeBoundaryKind.prohibited
            && !unit.isOpaque() && isWordCore(wordBreakClass(unit.value)))
            flags |= TextUnitFlags.wordStart;
        workspace.units[i] = TextUnit(
            value: unit.isOpaque() ? opaqueByteBase + unit.opaqueByte : unit.value,
            sourceStart: cast(uint) spans[0].start,
            sourceEnd: cast(uint) spans[$ - 1].end, flags: flags,
            provenanceStart: unit.provenanceStart, provenanceCount: unit.provenanceCount);
    }
    workspace.bank_ = current;
    workspace.length_ = view.units.length;
    workspace.deletionCount_ = view.deletions.length;
    result.length = workspace.length_;
    return result;
}

/// Reordering never turns an enclosing source range into exact provenance.
@("text.analysis.exactContributorsAndFailedPublication")
@safe pure nothrow @nogc
unittest
{
    AnalysisWorkspace!(8, 8) workspace;
    auto result = analyzeText("A\u0315\u0300",
        AnalysisOptions.codePath(AnalysisCase.sensitive), workspace);
    assert(result.succeeded && workspace.output[0].value == 0xC0);
    const sources = workspace.contributingSourceSpans(workspace.output[0]);
    assert(sources.length == 2);
    assert(sources[0] == UnicodeSourceSpan(0, 1));
    assert(sources[1] == UnicodeSourceSpan(3, 5));
    assert(workspace.contributingSourceSpans(workspace.output[1])[0] == UnicodeSourceSpan(1, 3));
    assert(workspace.output[0].sourceWasUppercase);
    auto options = AnalysisOptions.codePath();
    options.caseMode = cast(AnalysisCase) 255;
    result = analyzeText("abc", options, workspace);
    assert(result.error == AnalysisError.invalidOptions);
    assert(workspace.output.length == 0 && workspace.deletions.length == 0);
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

private UnicodeNormalization analysisForm(AnalysisNormalization form)
    @safe pure nothrow @nogc
{
    final switch (form)
    {
    case AnalysisNormalization.nfc: return UnicodeNormalization.NFC;
    case AnalysisNormalization.nfkc: return UnicodeNormalization.NFKC;
    case AnalysisNormalization.nfd: return UnicodeNormalization.NFD;
    case AnalysisNormalization.nfkd: return UnicodeNormalization.NFKD;
    }
}

private UnicodeCaseMode analysisCase(AnalysisCase mode)
    @safe pure nothrow @nogc
{
    final switch (mode)
    {
    case AnalysisCase.sensitive: assert(0, "Sensitive analysis does not invoke casing");
    case AnalysisCase.simpleFold: return UnicodeCaseMode.simpleFold;
    case AnalysisCase.fullFold: return UnicodeCaseMode.fullFold;
    case AnalysisCase.lower: return UnicodeCaseMode.lower;
    case AnalysisCase.upper: return UnicodeCaseMode.upper;
    case AnalysisCase.title: return UnicodeCaseMode.title;
    }
}

private AnalysisResult analysisFailure(in UnicodeResult status, AnalysisResult result)
    @safe pure nothrow @nogc
{
    result.error = status.status == UnicodeStatus.unsupportedLocale
        ? AnalysisError.unsupportedLocale
        : status.status == UnicodeStatus.workspaceFull || status.status == UnicodeStatus.outputFull
        ? AnalysisError.workspaceFull : AnalysisError.invalidOptions;
    result.sourceOffset = status.blocking.start;
    result.length = 0;
    return result;
}

// Enforce the caller's segment-storage policy even when an already ordered run
// needs no ordering scratch in the normalization core.
private AnalysisResult checkAnalysisSegments(in UnicodeTransformView input,
    UnicodeNormalization form, size_t capacity) @safe pure nothrow @nogc
{
    const compatible = form == UnicodeNormalization.NFKC || form == UnicodeNormalization.NFKD;
    size_t length;
    foreach (i, unit; input.units)
    {
        if (unit.isOpaque()) { length = 0; continue; }
        const mapping = compatible ? compatibilityDecomposition(unit.value)
            : canonicalDecomposition(unit.value);
        const count = mapping.present ? mapping.length : 1;
        foreach (j; 0 .. count)
        {
            const value = !mapping.present ? unit.value
                : compatible ? compatibilityDecompositionValue(mapping.offset + j)
                : canonicalDecompositionValue(mapping.offset + j);
            length = canonicalCombiningClass(value) == 0 ? 1 : length + 1;
            if (length > capacity)
                return AnalysisResult(error: AnalysisError.segmentTooLong,
                    sourceOffset: input.contributingSourceSpans(i)[0].start);
        }
    }
    return AnalysisResult.init;
}

private UnicodeResult analyzeWords(in UnicodeTransformView input,
    scope UtfToken[] tokens, scope UnicodeBoundary[] boundaries,
    scope WordBoundaryWorkspace[] scratch) @safe pure nothrow @nogc
{
    foreach (i, unit; input.units)
        tokens[i] = UtfToken(kind: unit.kind, scalar: unit.value,
            byteValue: unit.opaqueByte, start: i, end: i + 1);
    return wordBoundaries(tokens[0 .. input.units.length], boundaries, scratch);
}

private bool isWordCore(WordBreakClass kind) @safe pure nothrow @nogc
    => kind == WordBreakClass.aLetter || kind == WordBreakClass.hebrewLetter
        || kind == WordBreakClass.numeric || kind == WordBreakClass.katakana
        || kind == WordBreakClass.extendNumLet;

private bool isStopword(scope const(UnicodeTransformUnit)[] units,
    in StopwordLexicon lexicon) @safe pure nothrow @nogc
{
    foreach (word; lexicon.words)
    {
        if (word.units.length != units.length) continue;
        bool equal = true;
        foreach (i, value; word.units)
            if (units[i].isOpaque() || units[i].value != value)
            {
                equal = false;
                break;
            }
        if (equal) return true;
    }
    return false;
}

private UnicodeResult filterAnalysis(in UnicodeTransformView input,
    scope ref UnicodeTransformWorkspace output, bool marks, in StopwordLexicon lexicon,
    scope size_t[] boundaryMap, scope const(UnicodeBoundary)[] boundaries)
    @safe pure nothrow @nogc
{
    auto result = output.begin();
    if (!result.succeeded()) return result;
    size_t first;
    while (first < input.units.length)
    {
        size_t end = first + 1;
        if (!marks)
            while (end < input.units.length
                && boundaries[end].kind == UnicodeBoundaryKind.prohibited) ++end;
        const omitWord = !marks && isStopword(input.units[first .. end], lexicon);
        foreach (i; first .. end)
        {
            boundaryMap[i] = output.length();
            UnicodeTransformUnit unit = input.units[i];
            const sources = input.contributingSourceSpans(i);
            if (omitWord || (marks && !unit.isOpaque() && isUnicodeMark(unit.value)))
            {
                foreach (source; sources)
                {
                    result = output.appendDeletion(UnicodeDeletion(output.length(), source));
                    if (!result.succeeded()) return result;
                }
            }
            else
            {
                size_t provenance;
                result = output.appendSources(sources, provenance);
                if (!result.succeeded()) return result;
                unit.provenanceStart = provenance;
                result = output.appendUnit(unit);
                if (!result.succeeded()) return result;
            }
        }
        first = end;
    }
    boundaryMap[input.units.length] = output.length();
    foreach (deletion; input.deletions)
    {
        result = output.appendDeletion(UnicodeDeletion(boundaryMap[deletion.boundary], deletion.source));
        if (!result.succeeded()) return result;
    }
    output.publish();
    return UnicodeResult(written: output.length());
}
