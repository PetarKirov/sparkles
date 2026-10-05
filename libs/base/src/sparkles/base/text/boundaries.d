/**
 * Default Unicode 18 word and sentence boundaries (UAX #29 revision 49).
 *
 * Both operations publish every logical token position, including the two text
 * endpoints (one position for empty input). Opaque bytes are an extension: both
 * adjacent positions are allowed and Unicode context cannot cross the byte.
 * Replacement tokens participate as their scalar value. There is no dictionary,
 * abbreviation list, locale tailoring, allocation, or maximum segment length.
 *
 * Supply one workspace entry per input token and n + 1 output entries. Storage
 * must be pairwise disjoint. Input spans must be ordered and nonoverlapping;
 * boundary offsets are the following token's start, or the final token's end.
 * Empty input's endpoint is zero. Failures leave output and workspace unchanged;
 * required is the exact missing workspace count or output count for that status.
 * Success may overwrite only the used workspace and output prefixes. Workspace
 * contents are scratch, not a retained view or an incremental algorithm state.
 *
 * Authority: https://www.unicode.org/reports/tr29/tr29-49.html
 */
module sparkles.base.text.boundaries;

import sparkles.base.text.utf : UtfToken, UtfTokenKind, utfStorageOverlaps;
import sparkles.base.text.unicode_algorithm : UnicodeStatus, UnicodeResult,
    UnicodeSourceSpan, UnicodeBoundary, UnicodeBoundaryKind, validUnicodeToken;
import sparkles.base.text.unicode_tables : WordBreakClass, SentenceBreakClass,
    wordBreakClass, sentenceBreakClass, UnicodeProperty, unicodeProperty;

private alias WB = WordBreakClass;
private alias SB = SentenceBreakClass;

/// Caller scratch: exactly input.length entries, with no initialization required.
struct WordBoundaryWorkspace
{
    private WB property;
    private size_t previous;
    private size_t next;
}

/// Caller scratch: exactly input.length entries, with no initialization required.
struct SentenceBoundaryWorkspace
{
    private SB property;
    private bool lowerAhead;
}

private UnicodeResult preflight(W)(scope const(UtfToken)[] input,
    scope UnicodeBoundary[] output, scope W[] workspace)
{
    if (utfStorageOverlaps(input, output) || utfStorageOverlaps(input, workspace)
        || utfStorageOverlaps(workspace, output))
        return UnicodeResult(status: UnicodeStatus.overlap);
    foreach (i, token; input)
    {
        if (cast(uint) token.kind > cast(uint) UtfTokenKind.opaqueByte
            || !validUnicodeToken(token)
            || (i && input[i - 1].end > token.start))
            return UnicodeResult(status: UnicodeStatus.invalidInput,
                blocking: UnicodeSourceSpan(token.start, token.end));
    }
    if (input.length == size_t.max)
        return UnicodeResult(status: UnicodeStatus.overflow);
    if (workspace.length < input.length)
        return UnicodeResult(status: UnicodeStatus.workspaceFull, required: input.length);
    if (output.length < input.length + 1)
        return UnicodeResult(status: UnicodeStatus.outputFull, required: input.length + 1);
    return UnicodeResult(status: UnicodeStatus.ok, required: input.length + 1);
}

private bool wordIgnored(WB value) @safe pure nothrow @nogc
{
    return value == WB.extend || value == WB.format || value == WB.zwj;
}

private bool wordNewline(WB value) @safe pure nothrow @nogc
{
    return value == WB.cr || value == WB.lf || value == WB.newline;
}

private bool letter(WB value) @safe pure nothrow @nogc
{
    return value == WB.aLetter || value == WB.hebrewLetter;
}

private bool letterMiddle(WB value) @safe pure nothrow @nogc
{
    return value == WB.midLetter || value == WB.midNumLet || value == WB.singleQuote;
}

private bool numericMiddle(WB value) @safe pure nothrow @nogc
{
    return value == WB.midNum || value == WB.midNumLet || value == WB.singleQuote;
}

private bool extendedWord(WB value) @safe pure nothrow @nogc
{
    return letter(value) || value == WB.numeric || value == WB.katakana;
}

private size_t endpoint(scope const(UtfToken)[] input, size_t i)
    @safe pure nothrow @nogc
{
    return i < input.length ? input[i].start : input.length ? input[$ - 1].end : 0;
}

/**
 * Compute the complete default word boundary map in linear time.
 * required on workspaceFull is input.length; on outputFull/success it is n + 1.
 */
UnicodeResult wordBoundaries(scope const(UtfToken)[] input,
    scope UnicodeBoundary[] output, scope WordBoundaryWorkspace[] workspace)
    @safe pure nothrow @nogc
{
    auto result = preflight(input, output, workspace);
    if (!result.succeeded()) return result;
    const n = input.length;
    auto scratch = workspace[0 .. n];
    size_t previous = n;
    foreach (i, token; input)
    {
        auto property = token.kind == UtfTokenKind.opaqueByte
            ? WB.other : wordBreakClass(token.scalar);
        scratch[i] = WordBoundaryWorkspace(property, previous, n);
        if (!wordIgnored(property)) previous = i;
    }
    size_t next = n;
    foreach_reverse (i; 0 .. n)
    {
        scratch[i].next = next;
        if (!wordIgnored(scratch[i].property)) next = i;
    }
    bool oddRI;
    previous = n;
    foreach (i; 0 .. n + 1)
    {
        if (i)
        {
            const p = scratch[i - 1].property;
            if (!wordIgnored(p))
            {
                previous = i - 1;
                oddRI = p == WB.regionalIndicator ? !oddRI : false;
            }
        }
        bool boundary = true;
        if (i && i < n && input[i - 1].kind != UtfTokenKind.opaqueByte
            && input[i].kind != UtfTokenKind.opaqueByte)
        {
            const rawLeft = scratch[i - 1].property;
            const right = scratch[i].property;
            // WB3 through WB3d precede the ignore transformation: adjacency
            // matters for CRLF, ZWJ/emoji, and horizontal spaces.
            if (rawLeft == WB.cr && right == WB.lf) boundary = false;
            else if (wordNewline(rawLeft) || wordNewline(right)) boundary = true;
            else if (rawLeft == WB.zwj
                && unicodeProperty(input[i].scalar, UnicodeProperty.ExtPict)) boundary = false;
            else if (rawLeft == WB.wSegSpace && right == WB.wSegSpace) boundary = false;
            else if (wordIgnored(right)) boundary = false; // WB4
            else if (previous != n)
            {
                const left = scratch[previous].property;
                const beforeIndex = scratch[previous].previous;
                const before = beforeIndex == n ? WB.other : scratch[beforeIndex].property;
                const afterIndex = scratch[i].next;
                const after = afterIndex == n ? WB.other : scratch[afterIndex].property;
                if (letter(left) && letter(right)) boundary = false; // WB5
                else if (letter(left) && letterMiddle(right) && letter(after)) boundary = false; // WB6
                else if (letter(before) && letterMiddle(left) && letter(right)) boundary = false; // WB7
                else if (left == WB.hebrewLetter && right == WB.singleQuote) boundary = false; // WB7a
                else if (left == WB.hebrewLetter && right == WB.doubleQuote
                    && after == WB.hebrewLetter) boundary = false; // WB7b
                else if (before == WB.hebrewLetter && left == WB.doubleQuote
                    && right == WB.hebrewLetter) boundary = false; // WB7c
                else if (left == WB.numeric && right == WB.numeric) boundary = false; // WB8
                else if (letter(left) && right == WB.numeric) boundary = false; // WB9
                else if (left == WB.numeric && letter(right)) boundary = false; // WB10
                else if (before == WB.numeric && numericMiddle(left)
                    && right == WB.numeric) boundary = false; // WB11
                else if (left == WB.numeric && numericMiddle(right)
                    && after == WB.numeric) boundary = false; // WB12
                else if (left == WB.katakana && right == WB.katakana) boundary = false; // WB13
                else if ((extendedWord(left) || left == WB.extendNumLet)
                    && right == WB.extendNumLet) boundary = false; // WB13a
                else if (left == WB.extendNumLet && extendedWord(right)) boundary = false; // WB13b
                else if (left == WB.regionalIndicator && right == WB.regionalIndicator
                    && oddRI) boundary = false; // WB15/WB16
            }
        }
        output[i] = UnicodeBoundary(i, endpoint(input, i), boundary
            ? UnicodeBoundaryKind.allowed : UnicodeBoundaryKind.prohibited);
    }
    result.written = n + 1;
    return result;
}

private bool sentenceIgnored(SB value) @safe pure nothrow @nogc
{
    return value == SB.EX || value == SB.FO;
}

private bool paragraphSeparator(SB value) @safe pure nothrow @nogc
{
    return value == SB.SE || value == SB.CR || value == SB.LF;
}

private bool sentenceTerminator(SB value) @safe pure nothrow @nogc
{
    return value == SB.AT || value == SB.ST;
}

/**
 * Compute the complete default sentence boundary map in linear time.
 * Scratch caches the unbounded SB8 lookahead in a backward pass; forward state
 * matches SATerm Close* Sp* without repeatedly scanning punctuation or spaces.
 * required on workspaceFull is input.length; on outputFull/success it is n + 1.
 */
UnicodeResult sentenceBoundaries(scope const(UtfToken)[] input,
    scope UnicodeBoundary[] output, scope SentenceBoundaryWorkspace[] workspace)
    @safe pure nothrow @nogc
{
    auto result = preflight(input, output, workspace);
    if (!result.succeeded()) return result;
    const n = input.length;
    auto scratch = workspace[0 .. n];
    bool lowerAhead;
    foreach_reverse (i; 0 .. n)
    {
        const token = input[i];
        const p = token.kind == UtfTokenKind.opaqueByte ? SB.XX : sentenceBreakClass(token.scalar);
        if (token.kind == UtfTokenKind.opaqueByte) lowerAhead = false;
        else if (p == SB.LO) lowerAhead = true;
        else if (p == SB.LE || p == SB.UP || paragraphSeparator(p)
            || sentenceTerminator(p)) lowerAhead = false;
        scratch[i] = SentenceBoundaryWorkspace(p, lowerAhead);
    }
    SB previous = SB.XX;
    SB beforePrevious = SB.XX;
    SB terminator = SB.XX;
    bool spaces;
    foreach (i; 0 .. n + 1)
    {
        if (i)
        {
            const p = scratch[i - 1].property;
            if (input[i - 1].kind == UtfTokenKind.opaqueByte)
            {
                previous = beforePrevious = terminator = SB.XX;
                spaces = false;
            }
            else if (!sentenceIgnored(p))
            {
                beforePrevious = previous;
                previous = p;
                if (sentenceTerminator(p))
                {
                    terminator = p;
                    spaces = false;
                }
                else if (terminator != SB.XX && p == SB.CL && !spaces) {}
                else if (terminator != SB.XX && p == SB.SP) spaces = true;
                else
                {
                    terminator = SB.XX;
                    spaces = false;
                }
            }
        }
        bool boundary = i == 0 || i == n;
        if (i && i < n)
        {
            const rawLeft = scratch[i - 1].property;
            const right = scratch[i].property;
            if (input[i - 1].kind == UtfTokenKind.opaqueByte
                || input[i].kind == UtfTokenKind.opaqueByte) boundary = true;
            else if (rawLeft == SB.CR && right == SB.LF) boundary = false; // SB3
            else if (paragraphSeparator(rawLeft)) boundary = true; // SB4
            else if (sentenceIgnored(right)) boundary = false; // SB5
            else if (previous == SB.AT && right == SB.NU) boundary = false; // SB6
            else if ((beforePrevious == SB.UP || beforePrevious == SB.LO)
                && previous == SB.AT && right == SB.UP) boundary = false; // SB7
            else if (terminator == SB.AT && scratch[i].lowerAhead) boundary = false; // SB8
            else if (terminator != SB.XX && (right == SB.SC
                || sentenceTerminator(right))) boundary = false; // SB8a
            else if (terminator != SB.XX && !spaces
                && (right == SB.CL || right == SB.SP || paragraphSeparator(right))) boundary = false; // SB9
            else if (terminator != SB.XX
                && (right == SB.SP || paragraphSeparator(right))) boundary = false; // SB10
            else if (terminator != SB.XX) boundary = true; // SB11
            // SB998: otherwise no boundary.
        }
        output[i] = UnicodeBoundary(i, endpoint(input, i), boundary
            ? UnicodeBoundaryKind.allowed : UnicodeBoundaryKind.prohibited);
    }
    result.written = n + 1;
    return result;
}

version (unittest)
{
    private void checkBoundaries(bool sentence)(scope const(dchar)[] scalars,
        scope const(size_t)[] allowed)
    {
        UtfToken[64] tokens;
        UnicodeBoundary[65] output;
        WordBoundaryWorkspace[64] words;
        SentenceBoundaryWorkspace[64] sentences;
        assert(scalars.length <= tokens.length);
        foreach (i, scalar; scalars)
            tokens[i] = UtfToken(scalar: scalar, start: 100 + i * 2, end: 102 + i * 2);
        static if (sentence)
            const result = sentenceBoundaries(tokens[0 .. scalars.length], output[], sentences[]);
        else
            const result = wordBoundaries(tokens[0 .. scalars.length], output[], words[]);
        assert(result.succeeded() && result.written == scalars.length + 1);
        size_t cursor;
        foreach (i; 0 .. result.written)
        {
            const expected = cursor < allowed.length && allowed[cursor] == i;
            assert(output[i].kind == (expected
                ? UnicodeBoundaryKind.allowed : UnicodeBoundaryKind.prohibited));
            assert(output[i].index == i);
            assert(output[i].offset == (scalars.length ? 100 + i * 2 : 0));
            if (expected) ++cursor;
        }
        assert(cursor == allowed.length);
    }
}

@("text.boundaries.wordRuleInteractions")
@safe pure nothrow @nogc
unittest
{
    checkBoundaries!false(['a', '\u0308', ':', '\u00AD', 'b'], [0, 5]);
    checkBoundaries!false(['\u05D0', '"', '\u0308', '\u05D1', '\''], [0, 5]);
    checkBoundaries!false(['3', '\u0308', ',', '\u00AD', '4', '_', '\u30A2'], [0, 7]);
    checkBoundaries!false([' ', '\u0308', ' '], [0, 2, 3]);
    checkBoundaries!false(['\u200D', '\U0001F600'], [0, 2]);
    checkBoundaries!false(['\u200D', '\u0308', '\U0001F600'], [0, 2, 3]);
    checkBoundaries!false(['\U0001F1E6', '\u0308', '\U0001F1E7',
        '\u00AD', '\U0001F1E8', '\U0001F1E9'], [0, 4, 6]);
    checkBoundaries!false(['\r', '\n', '\u0308', 'a'], [0, 2, 3, 4]);
    checkBoundaries!false(['\u0308', '\u00AD', 'a'], [0, 2, 3]);
}

@("text.boundaries.sentenceRuleInteractions")
@safe pure nothrow @nogc
unittest
{
    checkBoundaries!true(['A', '.', '\u0308', 'B', '.', ' ', 'c'], [0, 7]);
    checkBoundaries!true(['A', '.', 'B', '.', ' ', 'C'], [0, 5, 6]);
    checkBoundaries!true(['a', '.', ')', ' ', '1', ',', ' ', 'b'], [0, 8]);
    checkBoundaries!true(['a', '!', ')', ' ', '1', ',', ' ', 'b'], [0, 4, 8]);
    checkBoundaries!true(['3', '.', '\u00AD', '4'], [0, 4]);
    checkBoundaries!true(['a', '!', ')', '\u0308', ' ', '\r', '\n',
        '\u0308', 'B'], [0, 7, 9]);
    checkBoundaries!true(['a', '!', ' ', ';', ' ', 'B'], [0, 6]);
    checkBoundaries!true(['\u0308', '\u00AD', 'a'], [0, 3]);
}

@("text.boundaries.opaqueBarriersAndSourceOffsets")
@safe pure nothrow @nogc
unittest
{
    UtfToken[6] tokens = [
        UtfToken(scalar: 'a', start: 8, end: 9),
        UtfToken(kind: UtfTokenKind.opaqueByte, byteValue: 0xFF, start: 9, end: 10),
        UtfToken(scalar: '\u0308', start: 10, end: 12),
        UtfToken(scalar: 'b', start: 12, end: 13),
        UtfToken(kind: UtfTokenKind.opaqueByte, byteValue: 0x80, start: 13, end: 14),
        UtfToken(kind: UtfTokenKind.replacement, scalar: '\uFFFD', start: 14, end: 17),
    ];
    UnicodeBoundary[7] output;
    WordBoundaryWorkspace[6] words;
    SentenceBoundaryWorkspace[6] sentences;
    assert(wordBoundaries(tokens[], output[], words[]).succeeded());
    foreach (i; 0 .. output.length)
        assert(output[i].kind == UnicodeBoundaryKind.allowed);
    assert(sentenceBoundaries(tokens[], output[], sentences[]).succeeded());
    foreach (i; 0 .. output.length)
        assert(output[i].kind == (i == 3
            ? UnicodeBoundaryKind.prohibited : UnicodeBoundaryKind.allowed));
    assert(output[0].offset == 8 && output[2].offset == 10
        && output[3].offset == 12 && output[6].offset == 17);

    // Neither SB8 lookahead nor word punctuation context can cross a raw byte.
    tokens[0].scalar = '.';
    tokens[2].scalar = 'a';
    assert(sentenceBoundaries(tokens[0 .. 3], output[], sentences[]).succeeded());
    assert(output[1].kind == UnicodeBoundaryKind.allowed
        && output[2].kind == UnicodeBoundaryKind.allowed);
}

@("text.boundaries.transactionalCapacityAndInvalidInput")
@safe pure nothrow @nogc
unittest
{
    UtfToken[2] tokens = [UtfToken(scalar: 'a', start: 4, end: 5),
        UtfToken(scalar: 'b', start: 5, end: 6)];
    UnicodeBoundary[3] output = UnicodeBoundary(99, 98, UnicodeBoundaryKind.mandatory);
    const original = output;
    WordBoundaryWorkspace[2] words;
    SentenceBoundaryWorkspace[2] sentences;
    const savedWords = words;
    const savedSentences = sentences;
    auto result = wordBoundaries(tokens[], output[], words[0 .. 1]);
    assert(result.status == UnicodeStatus.workspaceFull && result.required == 2
        && result.written == 0 && output == original && words == savedWords);
    result = sentenceBoundaries(tokens[], output[0 .. 2], sentences[]);
    assert(result.status == UnicodeStatus.outputFull && result.required == 3
        && result.written == 0 && output == original && sentences == savedSentences);
    tokens[1].scalar = cast(dchar) 0xD800;
    result = wordBoundaries(tokens[], output[0 .. 0], words[0 .. 0]);
    assert(result.status == UnicodeStatus.invalidInput
        && result.blocking.start == 5 && output == original && words == savedWords);
    tokens[1].scalar = 'b';
    tokens[1].kind = cast(UtfTokenKind) 255;
    assert(sentenceBoundaries(tokens[], output[], sentences[]).status
        == UnicodeStatus.invalidInput);
    tokens[1].kind = UtfTokenKind.scalar;
    tokens[1].start = 3;
    assert(wordBoundaries(tokens[], output[], words[]).status == UnicodeStatus.invalidInput);
    assert(output == original);
    result = wordBoundaries(tokens[0 .. 0], output[], words[0 .. 0]);
    assert(result.succeeded() && result.written == 1 && output[0].offset == 0
        && output[0].kind == UnicodeBoundaryKind.allowed && output[1] == original[1]);
    assert(sentenceBoundaries(tokens[0 .. 0], output[0 .. 0], sentences[0 .. 0]).status
        == UnicodeStatus.outputFull);
}

@("text.boundaries.storageOverlap")
@system pure nothrow @nogc
unittest
{
    union Storage
    {
        UtfToken[3] input;
        UnicodeBoundary[4] output;
        WordBoundaryWorkspace[3] words;
        SentenceBoundaryWorkspace[3] sentences;
    }
    Storage aliased;
    UtfToken[1] input = [UtfToken(scalar: 'a', start: 0, end: 1)];
    UnicodeBoundary[2] output;
    WordBoundaryWorkspace[1] words;
    SentenceBoundaryWorkspace[1] sentences;
    assert(wordBoundaries(input[], aliased.output[], aliased.words[]).status
        == UnicodeStatus.overlap);
    assert(sentenceBoundaries(aliased.input[], output[], aliased.sentences[]).status
        == UnicodeStatus.overlap);
    assert(wordBoundaries(aliased.input[], aliased.output[], words[]).status
        == UnicodeStatus.overlap);
}

@("text.boundaries.unboundedIgnoredAndSentenceLookahead")
@safe
unittest
{
    enum count = 70_003;
    auto tokens = new UtfToken[count];
    auto output = new UnicodeBoundary[count + 1];
    auto words = new WordBoundaryWorkspace[count];
    auto sentences = new SentenceBoundaryWorkspace[count];
    foreach (i, ref token; tokens)
        token = UtfToken(scalar: i == 0 || i == count - 1 ? 'a' : '\u0308',
            start: i, end: i + 1);
    assert(wordBoundaries(tokens, output, words).succeeded());
    foreach (i; 1 .. count)
        assert(output[i].kind == UnicodeBoundaryKind.prohibited);
    // Long SB8 negative-class lookahead, not just a long run of ignored marks.
    tokens[0].scalar = '.';
    foreach (ref token; tokens[1 .. $ - 1]) token.scalar = '1';
    assert(sentenceBoundaries(tokens, output, sentences).succeeded());
    foreach (i; 1 .. count)
        assert(output[i].kind == UnicodeBoundaryKind.prohibited);
    // A following Upper blocks SB8. SB6 still attaches the first numeric.
    tokens[$ - 1].scalar = 'A';
    tokens[1].scalar = ')';
    assert(sentenceBoundaries(tokens, output, sentences).succeeded());
    assert(output[2].kind == UnicodeBoundaryKind.allowed);
}
