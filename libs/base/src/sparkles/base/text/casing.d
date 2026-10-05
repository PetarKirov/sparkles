/** Unicode 18 full casing and folding, with caller-owned exact provenance. */
module sparkles.base.text.casing;

import sparkles.base.text.transform : UnicodeTransformUnit, UnicodeTransformView,
    UnicodeTransformWorkspace, UnicodeDeletion;
import sparkles.base.text.unicode_algorithm : UnicodeResult, UnicodeStatus,
    UnicodeSourceSpan, UnicodeBoundary, UnicodeBoundaryKind;
import sparkles.base.text.utf : UtfToken, UtfTokenKind, isUnicodeScalar, utfStorageOverlaps;
import sparkles.base.text.boundaries : WordBoundaryWorkspace, wordBoundaries;
import tables = sparkles.base.text.unicode_tables;

/// Root is the default Unicode language-independent casing policy.
enum UnicodeCaseLocale : ubyte { root, tr, az, lt }
enum UnicodeCaseMode : ubyte { lower, upper, title, simpleFold, fullFold }
enum UnicodeFoldMode : ubyte { defaultFold, turkic }

/** Supply contexts[n] and boundaryMap[n+1] for every operation. Title additionally
 * needs tokens[n], words[n+1], and wordWorkspace[n]. All arenas must be disjoint
 * from each other and from input and output. Contents need no initialization.
 * Token offsets used for word segmentation are logical indices, not source spans:
 * provenance can have been reordered or composed by a preceding transformation.
 */
struct UnicodeCasingScratch
{
    ubyte[] contexts;
    size_t[] boundaryMap;
    UtfToken[] tokens;
    UnicodeBoundary[] words;
    WordBoundaryWorkspace[] wordWorkspace;
}

/// Simple scalar mappings leave non-scalars unchanged; views reject non-scalars.
dchar unicodeSimpleLower(dchar value) @safe pure nothrow @nogc
    => isUnicodeScalar(value) ? tables.simpleLowercase(value) : value;
dchar unicodeSimpleUpper(dchar value) @safe pure nothrow @nogc
    => isUnicodeScalar(value) ? tables.simpleUppercase(value) : value;
dchar unicodeSimpleTitle(dchar value) @safe pure nothrow @nogc
    => isUnicodeScalar(value) ? tables.simpleTitlecase(value) : value;
/// Simple Turkic folding replaces only the two T mappings, not full expansions.
dchar unicodeSimpleFold(dchar value, UnicodeFoldMode mode = UnicodeFoldMode.defaultFold)
    @safe pure nothrow @nogc
{
    if (!isUnicodeScalar(value)) return value;
    if (mode == UnicodeFoldMode.turkic && (value == 0x49 || value == 0x130))
    {
        const mapping = tables.turkicCaseFold(value);
        return tables.turkicCaseFoldValue(mapping.offset);
    }
    return tables.simpleCaseFold(value);
}

private enum : ubyte
{
    finalSigma = 1, afterSoftDotted = 2, moreAbove = 4,
    beforeDot = 8, afterI = 16, titleUnit = 32, titleKeep = 64
}

private bool overlapsArenas(T)(scope T[] arena, in UnicodeTransformView input,
    scope ref UnicodeTransformWorkspace output)
{
    return utfStorageOverlaps(input.units, arena)
        || utfStorageOverlaps(input.spans, arena)
        || utfStorageOverlaps(input.deletions, arena)
        || utfStorageOverlaps(input.storageEpoch(), arena)
        || utfStorageOverlaps(arena, output.units)
        || utfStorageOverlaps(arena, output.spans)
        || utfStorageOverlaps(arena, output.deletions)
        || utfStorageOverlaps(arena, output.epoch);
}

private bool overlapping(in UnicodeTransformView input,
    scope ref UnicodeTransformWorkspace output, scope ref UnicodeCasingScratch scratch,
    bool title) @safe pure nothrow @nogc
{
    if (utfStorageOverlaps(input.units, output.units)
        || utfStorageOverlaps(input.units, output.spans)
        || utfStorageOverlaps(input.units, output.deletions)
        || utfStorageOverlaps(input.units, output.epoch)
        || utfStorageOverlaps(input.spans, output.units)
        || utfStorageOverlaps(input.spans, output.spans)
        || utfStorageOverlaps(input.spans, output.deletions)
        || utfStorageOverlaps(input.spans, output.epoch)
        || utfStorageOverlaps(input.deletions, output.units)
        || utfStorageOverlaps(input.deletions, output.spans)
        || utfStorageOverlaps(input.deletions, output.deletions)
        || utfStorageOverlaps(input.deletions, output.epoch)
        || utfStorageOverlaps(input.storageEpoch(), output.units)
        || utfStorageOverlaps(input.storageEpoch(), output.spans)
        || utfStorageOverlaps(input.storageEpoch(), output.deletions)
        || utfStorageOverlaps(input.storageEpoch(), output.epoch)
        || utfStorageOverlaps(output.units, output.spans)
        || utfStorageOverlaps(output.units, output.deletions)
        || utfStorageOverlaps(output.units, output.epoch)
        || utfStorageOverlaps(output.spans, output.deletions)
        || utfStorageOverlaps(output.spans, output.epoch)
        || utfStorageOverlaps(output.deletions, output.epoch)) return true;
    if (overlapsArenas(scratch.contexts, input, output)
        || overlapsArenas(scratch.boundaryMap, input, output)
        || utfStorageOverlaps(scratch.contexts, scratch.boundaryMap)) return true;
    if (!title) return false;
    return overlapsArenas(scratch.tokens, input, output)
        || overlapsArenas(scratch.words, input, output)
        || overlapsArenas(scratch.wordWorkspace, input, output)
        || utfStorageOverlaps(scratch.tokens, scratch.contexts)
        || utfStorageOverlaps(scratch.tokens, scratch.boundaryMap)
        || utfStorageOverlaps(scratch.words, scratch.contexts)
        || utfStorageOverlaps(scratch.words, scratch.boundaryMap)
        || utfStorageOverlaps(scratch.wordWorkspace, scratch.contexts)
        || utfStorageOverlaps(scratch.wordWorkspace, scratch.boundaryMap)
        || utfStorageOverlaps(scratch.tokens, scratch.words)
        || utfStorageOverlaps(scratch.tokens, scratch.wordWorkspace)
        || utfStorageOverlaps(scratch.words, scratch.wordWorkspace);
}

private UnicodeResult validate(in UnicodeTransformView input) @safe pure nothrow @nogc
{
    if (!input.valid()) return UnicodeResult(status: UnicodeStatus.staleView);
    foreach (span; input.spans)
        if (span.start > span.end)
            return UnicodeResult(status: UnicodeStatus.invalidInput, blocking: span);
    foreach (unit; input.units)
    {
        if (cast(uint) unit.kind > cast(uint) UtfTokenKind.opaqueByte
            || (!unit.isOpaque() && !isUnicodeScalar(unit.value))
            || unit.provenanceStart > input.spans.length
            || unit.provenanceCount > input.spans.length - unit.provenanceStart)
            return UnicodeResult(status: UnicodeStatus.invalidInput);
        const sources = input.spans[unit.provenanceStart .. unit.provenanceStart + unit.provenanceCount];
        foreach (i; 1 .. sources.length)
            if (sources[i - 1].start > sources[i].start
                || (sources[i - 1].start == sources[i].start && sources[i - 1].end >= sources[i].end))
                return UnicodeResult(status: UnicodeStatus.invalidInput, blocking: sources[i]);
    }
    foreach (deletion; input.deletions)
        if (deletion.boundary > input.units.length || deletion.source.start > deletion.source.end)
            return UnicodeResult(status: UnicodeStatus.invalidInput, blocking: deletion.source);
    return UnicodeResult.init;
}

// Evaluate every SpecialCasing context on the original string, in two linear
// passes. Opaque bytes reset every state. Case_Ignorable takes precedence over
// Cased when a scalar has both properties (notably U+0345).
private void contexts(in UnicodeTransformView input, scope ubyte[] flags)
    @safe pure nothrow @nogc
{
    bool casedBefore, soft, capitalI;
    foreach (i, unit; input.units)
    {
        flags[i] = 0;
        if (unit.isOpaque()) { casedBefore = soft = capitalI = false; continue; }
        if (casedBefore) flags[i] |= finalSigma;
        if (soft) flags[i] |= afterSoftDotted;
        if (capitalI) flags[i] |= afterI;
        const cp = unit.value;
        if (!tables.unicodeProperty(cp, tables.UnicodeProperty.CI))
            casedBefore = tables.unicodeProperty(cp, tables.UnicodeProperty.Cased);
        const ccc = tables.canonicalCombiningClass(cp);
        if (!ccc)
        {
            soft = tables.unicodeProperty(cp, tables.UnicodeProperty.SD);
            capitalI = cp == 0x49;
        }
        else if (ccc == 230) soft = capitalI = false;
    }
    bool casedAfter, above, dot;
    foreach_reverse (i; 0 .. input.units.length)
    {
        const unit = input.units[i];
        if (unit.isOpaque()) { casedAfter = above = dot = false; continue; }
        if (casedAfter) flags[i] &= cast(ubyte) ~finalSigma;
        if (above) flags[i] |= moreAbove;
        if (dot) flags[i] |= beforeDot;
        const cp = unit.value;
        if (!tables.unicodeProperty(cp, tables.UnicodeProperty.CI))
            casedAfter = tables.unicodeProperty(cp, tables.UnicodeProperty.Cased);
        const ccc = tables.canonicalCombiningClass(cp);
        if (ccc == 230) above = true;
        else if (!ccc) above = false;
        if (cp == 0x307) dot = true;
        else if (!ccc || ccc == 230) dot = false;
    }
}

private bool ruleMatches(scope const(char)[] condition, UnicodeCaseLocale locale,
    ubyte flags) @safe pure nothrow @nogc
{
    size_t i;
    while (i < condition.length)
    {
        while (i < condition.length && condition[i] == ' ') ++i;
        const first = i;
        while (i < condition.length && condition[i] != ' ') ++i;
        auto token = condition[first .. i];
        if (!token.length) continue;
        if (token == "tr" || token == "az" || token == "lt")
        {
            if ((token == "tr" && locale != UnicodeCaseLocale.tr)
                || (token == "az" && locale != UnicodeCaseLocale.az)
                || (token == "lt" && locale != UnicodeCaseLocale.lt)) return false;
            continue;
        }
        bool negate = token.length >= 4 && token[0 .. 4] == "Not_";
        if (negate) token = token[4 .. $];
        ubyte bit;
        if (token == "Final_Sigma") bit = finalSigma;
        else if (token == "After_Soft_Dotted") bit = afterSoftDotted;
        else if (token == "More_Above") bit = moreAbove;
        else if (token == "Before_Dot") bit = beforeDot;
        else if (token == "After_I") bit = afterI;
        else return false;
        if (((flags & bit) != 0) == negate) return false;
    }
    return true;
}

private enum MappingOwner : ubyte { identity, lower, upper, title, fold, turkic, contextual }
private struct Mapping
{
    tables.UnicodeMappingSpan span;
    MappingOwner owner;
    dchar scalar;
    size_t length() const @safe pure nothrow @nogc
        => owner == MappingOwner.identity ? 1 : span.length;
    dchar at(size_t i) const @safe pure nothrow @nogc
    {
        const offset = cast(size_t) span.offset + i;
        final switch (owner)
        {
        case MappingOwner.identity: return scalar;
        case MappingOwner.lower: return tables.fullLowercaseValue(offset);
        case MappingOwner.upper: return tables.fullUppercaseValue(offset);
        case MappingOwner.title: return tables.fullTitlecaseValue(offset);
        case MappingOwner.fold: return tables.fullCaseFoldValue(offset);
        case MappingOwner.turkic: return tables.turkicCaseFoldValue(offset);
        case MappingOwner.contextual: return tables.contextualCaseValue(offset);
        }
    }
}

private Mapping mapping(in UnicodeTransformUnit unit, UnicodeCaseMode mode,
    UnicodeCaseLocale locale, UnicodeFoldMode foldMode, ubyte flags)
    @safe pure nothrow @nogc
{
    Mapping result = Mapping(scalar: unit.value);
    if (unit.isOpaque()) return result;
    if (mode == UnicodeCaseMode.simpleFold)
    {
        result.scalar = unicodeSimpleFold(unit.value, foldMode);
        return result;
    }
    if (mode == UnicodeCaseMode.fullFold)
    {
        result.owner = foldMode == UnicodeFoldMode.turkic ? MappingOwner.turkic : MappingOwner.fold;
        result.span = foldMode == UnicodeFoldMode.turkic
            ? tables.turkicCaseFold(unit.value) : tables.fullCaseFold(unit.value);
    }
    else
    {
        if (mode == UnicodeCaseMode.title)
        {
            if (flags & titleKeep) return result;
            if (!(flags & titleUnit)) mode = UnicodeCaseMode.lower;
        }
        // Language/context rules override unconditional full mappings. The
        // generated rules retain SpecialCasing order; current locale rules do
        // not collide with the language-independent Final_Sigma rule.
        foreach (rule; tables.contextualCaseRules)
        {
            if (rule.codepoint != unit.value || !ruleMatches(rule.condition, locale, flags)) continue;
            result.span = mode == UnicodeCaseMode.lower ? rule.lower
                : mode == UnicodeCaseMode.upper ? rule.upper : rule.title;
            result.owner = MappingOwner.contextual;
            return result;
        }
        if (mode == UnicodeCaseMode.lower)
        {
            result.span = tables.fullLowercase(unit.value); result.owner = MappingOwner.lower;
        }
        else if (mode == UnicodeCaseMode.upper)
        {
            result.span = tables.fullUppercase(unit.value); result.owner = MappingOwner.upper;
        }
        else
        {
            result.span = tables.fullTitlecase(unit.value); result.owner = MappingOwner.title;
        }
    }
    if (!result.span.present) result.owner = MappingOwner.identity;
    return result;
}

/** Whole-operation full lower/upper/title or simple/full folding. Locale is
 * exactly "" (root), "tr", "az", or "lt"; every other requested tag fails.
 * Folding is independent of casing locale and uses the explicit foldMode.
 * Failure invalidates earlier output and publishes no partial view. required is
 * the exact needed count in the exhausted arena; blocking is the first source
 * relationship whose addition exceeds that arena. Expansions copy one source
 * set and share it; deletions retain all spans at the remapped logical boundary.
 * Each workspace epoch must be distinct and disjoint from all input, output and
 * scratch arenas. This storage precondition is asserted before invalidation.
 */
UnicodeResult caseTransform(in UnicodeTransformView input,
    scope ref UnicodeTransformWorkspace output, UnicodeCaseMode mode,
    scope ref UnicodeCasingScratch scratch, scope const(char)[] locale = "",
    UnicodeFoldMode foldMode = UnicodeFoldMode.defaultFold) @safe pure nothrow @nogc
{
    assert(!utfStorageOverlaps(input.units, output.epoch)
        && !utfStorageOverlaps(input.spans, output.epoch)
        && !utfStorageOverlaps(input.deletions, output.epoch)
        && !utfStorageOverlaps(input.storageEpoch(), output.epoch)
        && !utfStorageOverlaps(output.units, output.epoch)
        && !utfStorageOverlaps(output.spans, output.epoch)
        && !utfStorageOverlaps(output.deletions, output.epoch)
        && !utfStorageOverlaps(scratch.contexts, output.epoch)
        && !utfStorageOverlaps(scratch.boundaryMap, output.epoch)
        && !utfStorageOverlaps(scratch.tokens, output.epoch)
        && !utfStorageOverlaps(scratch.words, output.epoch)
        && !utfStorageOverlaps(scratch.wordWorkspace, output.epoch),
        "casing output epoch must be distinct and disjoint from all arenas");
    auto result = output.begin();
    if (!result.succeeded()) return result;
    const title = mode == UnicodeCaseMode.title;
    if (overlapping(input, output, scratch, title))
        return UnicodeResult(status: UnicodeStatus.overlap);
    result = validate(input);
    if (!result.succeeded()) return result;
    UnicodeCaseLocale language;
    if (locale == "") language = UnicodeCaseLocale.root;
    else if (locale == "tr") language = UnicodeCaseLocale.tr;
    else if (locale == "az") language = UnicodeCaseLocale.az;
    else if (locale == "lt") language = UnicodeCaseLocale.lt;
    else return UnicodeResult(status: UnicodeStatus.unsupportedLocale);
    if (cast(uint) mode > cast(uint) UnicodeCaseMode.fullFold
        || cast(uint) foldMode > cast(uint) UnicodeFoldMode.turkic)
        return UnicodeResult(status: UnicodeStatus.invalidOptions);
    const n = input.units.length;
    if (n == size_t.max) return UnicodeResult(status: UnicodeStatus.overflow);
    if (scratch.contexts.length < n)
        return UnicodeResult(status: UnicodeStatus.workspaceFull, required: n);
    if (scratch.boundaryMap.length < n + 1)
        return UnicodeResult(status: UnicodeStatus.workspaceFull, required: n + 1);
    auto flags = scratch.contexts[0 .. n];
    if (mode == UnicodeCaseMode.simpleFold || mode == UnicodeCaseMode.fullFold) flags[] = 0;
    else contexts(input, flags);
    if (title)
    {
        if (scratch.tokens.length < n || scratch.wordWorkspace.length < n)
            return UnicodeResult(status: UnicodeStatus.workspaceFull, required: n);
        if (scratch.words.length < n + 1)
            return UnicodeResult(status: UnicodeStatus.workspaceFull, required: n + 1);
        foreach (i, unit; input.units)
            scratch.tokens[i] = UtfToken(scalar: unit.value, kind: unit.kind,
                byteValue: unit.opaqueByte, start: i, end: i + 1);
        result = wordBoundaries(scratch.tokens[0 .. n], scratch.words[0 .. n + 1],
            scratch.wordWorkspace[0 .. n]);
        if (!result.succeeded()) return result;
        bool seenCased;
        foreach (i, unit; input.units)
        {
            if (scratch.words[i].kind != UnicodeBoundaryKind.prohibited) seenCased = false;
            if (!seenCased)
            {
                if (!unit.isOpaque() && tables.unicodeProperty(unit.value, tables.UnicodeProperty.Cased))
                {
                    flags[i] |= titleUnit; seenCased = true;
                }
                else flags[i] |= titleKeep;
            }
        }
    }
    size_t unitCount, spanCount, deletionCount = input.deletions.length;
    UnicodeSourceSpan unitBlock, spanBlock, deletionBlock;
    bool blockedUnits, blockedSpans, blockedDeletions;
    foreach (i, unit; input.units)
    {
        scratch.boundaryMap[i] = unitCount;
        const map = mapping(unit, mode, language, foldMode, flags[i]);
        const sources = input.contributingSourceSpans(i);
        if (map.length > size_t.max - unitCount
            || (map.length ? sources.length > size_t.max - spanCount
                : sources.length > size_t.max - deletionCount))
            return UnicodeResult(status: UnicodeStatus.overflow);
        unitCount += map.length;
        if (map.length) spanCount += sources.length;
        else deletionCount += sources.length;
        const source = sources.length ? sources[0] : UnicodeSourceSpan.init;
        if (!blockedUnits && unitCount > output.units.length) { unitBlock = source; blockedUnits = true; }
        if (!blockedSpans && spanCount > output.spans.length) { spanBlock = source; blockedSpans = true; }
        if (!blockedDeletions && deletionCount > output.deletions.length) { deletionBlock = source; blockedDeletions = true; }
    }
    scratch.boundaryMap[n] = unitCount;
    if (unitCount > output.units.length)
        return UnicodeResult(status: UnicodeStatus.outputFull, required: unitCount, blocking: unitBlock);
    if (spanCount > output.spans.length)
        return UnicodeResult(status: UnicodeStatus.workspaceFull, required: spanCount, blocking: spanBlock);
    if (deletionCount > output.deletions.length)
    {
        if (input.deletions.length > output.deletions.length)
            deletionBlock = input.deletions[output.deletions.length].source;
        return UnicodeResult(status: UnicodeStatus.workspaceFull, required: deletionCount, blocking: deletionBlock);
    }
    foreach (i, unit; input.units)
    {
        const map = mapping(unit, mode, language, foldMode, flags[i]);
        const sources = input.contributingSourceSpans(i);
        if (!map.length)
        {
            foreach (source; sources)
            {
                result = output.appendDeletion(UnicodeDeletion(scratch.boundaryMap[i], source));
                if (!result.succeeded()) return result;
            }
            continue;
        }
        size_t first;
        result = output.appendSources(sources, first);
        if (!result.succeeded()) return result;
        foreach (j; 0 .. map.length)
        {
            UnicodeTransformUnit mapped = unit;
            mapped.value = map.at(j);
            mapped.provenanceStart = first;
            result = output.appendUnit(mapped);
            if (!result.succeeded()) return result;
        }
    }
    foreach (deletion; input.deletions)
    {
        result = output.appendDeletion(UnicodeDeletion(scratch.boundaryMap[deletion.boundary], deletion.source));
        if (!result.succeeded()) return result;
    }
    output.publish();
    return UnicodeResult(status: UnicodeStatus.ok, written: unitCount, required: unitCount);
}

@("text.casing.contextLocaleTitleAndProvenance")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.text.transform : UnicodeTransformEpoch;
    UnicodeTransformUnit[32] inputUnits;
    UnicodeSourceSpan[32] inputSpans;
    UnicodeDeletion[8] inputDeleted;
    UnicodeTransformEpoch[1] inputEpoch;
    auto input = UnicodeTransformWorkspace(units: inputUnits[], spans: inputSpans[],
        deletions: inputDeleted[], epoch: inputEpoch[]);
    UnicodeTransformUnit[64] outputUnits;
    UnicodeSourceSpan[64] outputSpans;
    UnicodeDeletion[16] outputDeleted;
    UnicodeTransformEpoch[1] outputEpoch;
    auto output = UnicodeTransformWorkspace(units: outputUnits[], spans: outputSpans[],
        deletions: outputDeleted[], epoch: outputEpoch[]);
    ubyte[32] context;
    size_t[33] boundaryMap;
    UtfToken[32] tokens;
    UnicodeBoundary[33] words;
    WordBoundaryWorkspace[32] wordWorkspace;
    auto scratch = UnicodeCasingScratch(context[], boundaryMap[], tokens[],
        words[], wordWorkspace[]);
    void source(scope const(dchar)[] value)
    {
        assert(input.begin().succeeded());
        foreach (i, cp; value)
        {
            UnicodeSourceSpan[1] spans = [UnicodeSourceSpan(i * 2, i * 2 + 2)];
            size_t first;
            assert(input.appendSources(spans[], first).succeeded());
            assert(input.appendUnit(UnicodeTransformUnit(value: cp,
                provenanceStart: first, provenanceCount: 1)).succeeded());
        }
        input.publish();
    }
    void check(scope const(dchar)[] value, scope const(dchar)[] expected,
        UnicodeCaseMode mode, scope const(char)[] locale = "",
        UnicodeFoldMode fold = UnicodeFoldMode.defaultFold)
    {
        source(value);
        assert(caseTransform(input.output(), output, mode, scratch, locale, fold).succeeded());
        const view = output.output();
        assert(view.valid() && view.units.length == expected.length);
        foreach (i, cp; expected) assert(view.units[i].value == cp);
    }
    check("ΟΣ"d, "ος"d, UnicodeCaseMode.lower);
    check("ΟΣΑ"d, "οσα"d, UnicodeCaseMode.lower);
    check("Σ"d, "σ"d, UnicodeCaseMode.lower);
    check("Α\u0345Σ\u0301"d, "α\u0345ς\u0301"d, UnicodeCaseMode.lower);
    check("\u0345Σ"d, "\u0345σ"d, UnicodeCaseMode.lower);
    check("I\u0307X"d, "ix"d, UnicodeCaseMode.lower, "tr");
    auto view = output.output();
    assert(view.deletions.length == 1);
    assert(view.deletions[0] == UnicodeDeletion(1, UnicodeSourceSpan(2, 4)));
    assert(view.contributingSourceSpans(0)[0] == UnicodeSourceSpan(0, 2));
    check("I\u0323\u0307"d, "i\u0323"d, UnicodeCaseMode.lower, "az");
    check("I\u0301\u0307"d, "\u0131\u0301\u0307"d, UnicodeCaseMode.lower, "tr");
    check("I\u0301 J\u0300 \u012E\u0301"d, "i\u0307\u0301 j\u0307\u0300 \u012F\u0307\u0301"d,
        UnicodeCaseMode.lower, "lt");
    check("i\u0307\u0301"d, "I\u0301"d, UnicodeCaseMode.upper, "lt");
    check("i\u0301\u0307"d, "I\u0301\u0307"d, UnicodeCaseMode.upper, "lt");
    check("\u00CC\u00CD\u0128"d, "i\u0307\u0300i\u0307\u0301i\u0307\u0303"d,
        UnicodeCaseMode.lower, "lt");
    check("'hELLO can't ΣΟΣ \u01F3ABC \uFB03OO"d, "'Hello Can't Σος \u01F2abc Ffioo"d,
        UnicodeCaseMode.title);
    check("a\u0301BC'dEF 42fOO"d, "A\u0301bc'def 42Foo"d, UnicodeCaseMode.title);
    check("\u00DF\uFB03\u0130"d, "ssffii\u0307"d, UnicodeCaseMode.fullFold);
    view = output.output();
    assert(view.units[0].provenanceStart == view.units[1].provenanceStart);
    assert(view.spans.length == 3);
    assert(view.contributingSourceSpans(1)[0] == UnicodeSourceSpan(0, 2));
    check("AI\u0130\u00DF"d, "a\u0131iss"d, UnicodeCaseMode.fullFold, "", UnicodeFoldMode.turkic);
    check("I\u0130\u00DF"d, "\u0131i\u00DF"d, UnicodeCaseMode.simpleFold, "", UnicodeFoldMode.turkic);
    source("I\u0307\u00DF"d);
    assert(input.begin().succeeded());
    UnicodeSourceSpan[2] sources = [UnicodeSourceSpan(0, 1), UnicodeSourceSpan(7, 9)];
    size_t first;
    assert(input.appendSources(sources[], first).succeeded());
    assert(input.appendUnit(UnicodeTransformUnit(value: '\u00DF',
        provenanceStart: first, provenanceCount: 2)).succeeded());
    assert(input.appendDeletion(UnicodeDeletion(1, UnicodeSourceSpan(3, 4))).succeeded());
    input.publish();
    assert(caseTransform(input.output(), output, UnicodeCaseMode.fullFold, scratch).succeeded());
    view = output.output();
    assert(view.contributingSourceSpans(0) == sources[]);
    assert(view.contributingSourceSpans(1) == sources[]);
    assert(view.deletions[0] == UnicodeDeletion(2, UnicodeSourceSpan(3, 4)));
    source("ΑΙΣ"d);
    input.constructionUnits()[1].kind = UtfTokenKind.opaqueByte;
    input.constructionUnits()[1].opaqueByte = 0xFF;
    assert(caseTransform(input.output(), output, UnicodeCaseMode.lower, scratch).succeeded());
    view = output.output();
    assert(view.units[1].isOpaque() && view.units[1].opaqueByte == 0xFF);
    assert(view.contributingSourceSpans(1)[0] == UnicodeSourceSpan(2, 4));
    assert(view.units[2].value == '\u03C3');
    const prior = view;
    assert(caseTransform(input.output(), output, UnicodeCaseMode.lower, scratch, "en").status
        == UnicodeStatus.unsupportedLocale);
    assert(!prior.valid() && !output.output().valid() && output.output().units.length == 0);
    source("\u00DF\uFB03"d);
    output.units = outputUnits[0 .. 1];
    auto failure = caseTransform(input.output(), output, UnicodeCaseMode.fullFold, scratch);
    assert(failure.status == UnicodeStatus.outputFull && failure.required == 5 && failure.written == 0);
    assert(!output.output().valid());
    output.units = outputUnits[];
    output.spans = outputSpans[0 .. 1];
    failure = caseTransform(input.output(), output, UnicodeCaseMode.fullFold, scratch);
    assert(failure.status == UnicodeStatus.workspaceFull && failure.required == 2);
    assert(!output.output().valid());
    output.spans = outputSpans[];
    scratch.contexts = context[0 .. 1];
    failure = caseTransform(input.output(), output, UnicodeCaseMode.lower, scratch);
    assert(failure.status == UnicodeStatus.workspaceFull && failure.required == 2);
    assert(!output.output().valid());
    scratch.contexts = context[];
    source("I\u0307"d);
    output.deletions = outputDeleted[0 .. 0];
    failure = caseTransform(input.output(), output, UnicodeCaseMode.lower, scratch, "tr");
    assert(failure.status == UnicodeStatus.workspaceFull && failure.required == 1);
    assert(failure.blocking == UnicodeSourceSpan(2, 4) && !output.output().valid());
    output.deletions = outputDeleted[];
    input.constructionUnits()[0].value = cast(dchar) 0xD800;
    assert(caseTransform(input.output(), output, UnicodeCaseMode.lower, scratch).status
        == UnicodeStatus.invalidInput);
    assert(!output.output().valid());
    input.constructionUnits()[0].value = 'A';
    output.units = inputUnits[];
    assert(caseTransform(input.output(), output, UnicodeCaseMode.lower, scratch).status
        == UnicodeStatus.overlap);
    assert(!output.output().valid() && input.output().valid());
}
