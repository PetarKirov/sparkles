/**
Grapheme and word boundaries from an arbitrary position.

An editor asks for one boundary at a time, near the caret, in either
direction, over text it may hold in chunks rather than one slice. Every query
here answers exactly as segmenting the whole source would, without doing so:
it walks back to a _synchronisation token_, a scalar after which no rule
depends on earlier text, and runs the forward rules from there. A plain letter,
digit, space or punctuation mark is one, so the walk is usually a few bytes;
regional-indicator runs, Indic conjuncts and emoji sequences are walked in
full, which is what makes their answers exact.

A source is a `const(char)[]` or any $(LREF isChunkedSource) type. Bytes are
decoded with maximal-subpart replacement: each malformed subpart is one
U+FFFD scalar, as `UtfMode.replacement` defines. An offset inside a UTF-8
sequence is treated as the start of that sequence.

Specification: `docs/specs/base/text/SPEC.md` §4.3 (TXT-SEG7–9).
*/
module sparkles.base.text.seek;

import sparkles.base.text.grapheme : GraphemeBreakState;
import sparkles.base.text.unicode_algorithm : UnicodeSourceSpan;
import sparkles.base.text.unicode_tables : GeneralCategory, GraphemeBreakClass,
    IndicConjunctBreakClass, UnicodeProperty, WordBreakClass, unicodeCoreProperties,
    unicodeProperty, wordBreakClass;
import sparkles.base.text.utf : UtfMode, decodeToken;

/// One borrowed slice of a chunked source and the absolute offset it starts at.
struct SourceChunk
{
    size_t start;
    const(char)[] bytes;
}

/**
Whether `S` is a chunked source: it reports its `length` in bytes and
`chunkAt(offset)` returns the nonempty chunk containing byte `offset`, for
every `offset < length`. Consecutive chunks tile the source without gaps; a
chunk may end inside a UTF-8 sequence or a grapheme cluster.
*/
enum bool isChunkedSource(S) = is(typeof((ref S source) {
    size_t length = source.length;
    SourceChunk chunk = source.chunkAt(size_t(0));
}));

/// A single slice as the trivial chunked source.
struct SliceSource
{
    const(char)[] bytes;

    size_t length() const scope @safe pure nothrow @nogc => bytes.length;

    SourceChunk chunkAt(size_t offset) const return scope @safe pure nothrow @nogc
    in (offset < bytes.length, "offset is outside the source")
        => SourceChunk(0, bytes);
}

static assert(isChunkedSource!SliceSource);

/// Whether a seek query accepts `S`: a slice of UTF-8 or a chunked source.
enum bool isSeekSource(S) = isChunkedSource!S || is(S : const(char)[]);

/**
The kind of a word segment: `word` holds a letter, number or connector
punctuation scalar (General_Category `L*`, `N*` or `Pc`); `space` holds only
`White_Space` scalars; `other` is everything else, such as punctuation or a
symbol. An empty segment is `space`.
*/
enum WordSegmentKind : ubyte
{
    word,
    space,
    other,
}

/// A default UAX #29 word segment `[start, end)` and its kind.
struct WordSegment
{
    size_t start;
    size_t end;
    WordSegmentKind kind;
}

/**
The nearest grapheme boundary strictly after `at`, or `source.length` if none.

The answer equals the one implied by segmenting the whole source.
*/
size_t nextGraphemeBoundary(S)(auto ref S source, size_t at)
if (isSeekSource!S)
    => withChunks!(seekNext!false.seek)(source, at);

/**
The nearest grapheme boundary strictly before `at`, or 0 if none.

The work is linear in the distance from `at` back to the nearest
synchronisation token.
*/
size_t previousGraphemeBoundary(S)(auto ref S source, size_t at)
if (isSeekSource!S)
    => withChunks!(seekPrevious!false.seek)(source, at);

/// Whether `at` is a grapheme boundary. An offset inside a UTF-8 sequence is not.
bool isGraphemeBoundary(S)(auto ref S source, size_t at)
if (isSeekSource!S)
    => withChunks!isBoundaryImpl(source, at);

///
@("seek.grapheme.examples")
@safe pure nothrow @nogc
unittest
{
    enum text = "é\U0001F1FA\U0001F1F8\U0001F1E6\r\n";
    // e + combining acute | US flag | lone A indicator | CR LF
    assert(nextGraphemeBoundary(text, 0) == 3);
    assert(nextGraphemeBoundary(text, 3) == 11);
    assert(nextGraphemeBoundary(text, 11) == 15);
    assert(previousGraphemeBoundary(text, 15) == 11);
    assert(previousGraphemeBoundary(text, 17) == 15);
    assert(isGraphemeBoundary(text, 11) && !isGraphemeBoundary(text, 7));
    assert(!isGraphemeBoundary(text, 16), "CR LF is one cluster");
    assert(!isGraphemeBoundary(text, 2), "inside the acute's encoding");
}

/**
The word segment adjacent to `at` going forward: the one with
`start <= at < end`. At the source end it is empty.

Segments are delimited by positions that are both default UAX #29 word
boundaries and grapheme boundaries, so a segment never splits a cluster.
*/
WordSegment nextWordSegment(S)(auto ref S source, size_t at)
if (isSeekSource!S)
    => withChunks!(segmentAround!false.seek)(source, at);

/**
The word segment adjacent to `at` going backward: the one with
`start < at <= end`. At offset 0 it is empty.
*/
WordSegment previousWordSegment(S)(auto ref S source, size_t at)
if (isSeekSource!S)
    => withChunks!(segmentAround!true.seek)(source, at);

///
@("seek.wordSegment.examples")
@safe pure nothrow @nogc
unittest
{
    enum text = "can't stop, 3.14";
    assert(nextWordSegment(text, 0) == WordSegment(0, 5, WordSegmentKind.word));
    assert(nextWordSegment(text, 2) == WordSegment(0, 5, WordSegmentKind.word));
    assert(nextWordSegment(text, 5) == WordSegment(5, 6, WordSegmentKind.space));
    assert(previousWordSegment(text, 11) == WordSegment(10, 11, WordSegmentKind.other));
    assert(previousWordSegment(text, 16) == WordSegment(12, 16, WordSegmentKind.word));
    assert(previousWordSegment(text, 0) == WordSegment(0, 0, WordSegmentKind.space));
    assert(nextWordSegment(text, 16) == WordSegment(16, 16, WordSegmentKind.space));
}

/**
The nearest run of non-blank graphemes that ends after `at`: the run holding
`at`, or else the first run after it. A grapheme is blank when its first
scalar is `White_Space`. With no such run the result is empty at the end.

Run ends are grapheme boundaries, and the run is maximal: the graphemes on
either side of it are blank or absent.
*/
UnicodeSourceSpan nextBlankDelimited(S)(auto ref S source, size_t at)
if (isSeekSource!S)
    => withChunks!nextBlankImpl(source, at);

/**
The nearest run of non-blank graphemes that starts before `at`: the run
holding `at`, or else the last run before it. The run may end after `at`.
With no such run the result is empty at 0.

This is Readline's `unix-word-rubout` word: `Ctrl-W` removes
`[result.start, at)`.
*/
UnicodeSourceSpan previousBlankDelimited(S)(auto ref S source, size_t at)
if (isSeekSource!S)
    => withChunks!previousBlankImpl(source, at);

///
@("seek.blankDelimited.examples")
@safe pure nothrow @nogc
unittest
{
    enum text = "ls  /usr/lib  ";
    assert(previousBlankDelimited(text, 14) == UnicodeSourceSpan(4, 12));
    assert(previousBlankDelimited(text, 8) == UnicodeSourceSpan(4, 12));
    assert(previousBlankDelimited(text, 4) == UnicodeSourceSpan(0, 2));
    assert(previousBlankDelimited(text, 0) == UnicodeSourceSpan(0, 0));
    assert(nextBlankDelimited(text, 2) == UnicodeSourceSpan(4, 12));
    assert(nextBlankDelimited(text, 12) == UnicodeSourceSpan(14, 14));
    assert(previousBlankDelimited("   ", 3) == UnicodeSourceSpan(0, 0));
}

private:

auto withChunks(alias impl, S)(auto ref S source, size_t at)
{
    static if (isChunkedSource!S)
        return impl(source, at);
    else
    {
        auto slice = SliceSource(source);
        return impl(slice, at);
    }
}

struct Token
{
    dchar scalar;
    size_t start;
    size_t end;
}

bool isContinuation(ubyte b) @safe pure nothrow @nogc => (b & 0xC0) == 0x80;

/// Byte access and token decoding over a chunked source, caching one chunk.
struct Reader(S)
{
    S* source;
    size_t length;
    SourceChunk cache;

    ubyte at(size_t i) scope
    {
        if (i < cache.start || i - cache.start >= cache.bytes.length)
        {
            cache = source.chunkAt(i);
            assert(i >= cache.start && i - cache.start < cache.bytes.length,
                "chunkAt must return the chunk containing the offset");
        }
        return cast(ubyte) cache.bytes[i - cache.start];
    }

    /// The token starting at `i < length`. Every byte that is not a
    /// continuation byte starts a token, so a caller can find starts by
    /// scanning back to one; see `tokenStartBefore`.
    Token decode(size_t i) scope
    {
        char[4] window = void;
        const n = length - i < window.length ? length - i : window.length;
        foreach (k; 0 .. n)
            window[k] = cast(char) at(i + k);
        const decoded = decodeToken(window[0 .. n], UtfMode.replacement);
        return Token(decoded.token.scalar, i, i + decoded.result.consumed);
    }

    /// Start of the token holding byte `i - 1`, for `0 < i <= length`.
    size_t tokenStartBefore(size_t i) scope
    {
        size_t q = i - 1;
        foreach (_; 0 .. 3)
        {
            if (q == 0 || !isContinuation(at(q)))
                break;
            --q;
        }
        if (isContinuation(at(q)))
            return i - 1; // a stray continuation byte is a token by itself
        return decode(q).end >= i ? q : i - 1;
    }

    /// Start of the token holding offset `i`, or `i` at the end.
    size_t tokenStart(size_t i) scope => i == length ? i : tokenStartBefore(i + 1);
}

Reader!S reader(S)(return ref S source) => Reader!S(&source, source.length);

alias WB = WordBreakClass;

bool wordIgnored(WB c) @safe pure nothrow @nogc
    => c == WB.extend || c == WB.format || c == WB.zwj;

bool wordNewline(WB c) @safe pure nothrow @nogc
    => c == WB.cr || c == WB.lf || c == WB.newline;

bool letter(WB c) @safe pure nothrow @nogc => c == WB.aLetter || c == WB.hebrewLetter;

bool letterMiddle(WB c) @safe pure nothrow @nogc
    => c == WB.midLetter || c == WB.midNumLet || c == WB.singleQuote;

bool numericMiddle(WB c) @safe pure nothrow @nogc
    => c == WB.midNum || c == WB.midNumLet || c == WB.singleQuote;

bool extendedWord(WB c) @safe pure nothrow @nogc
    => letter(c) || c == WB.numeric || c == WB.katakana;

/**
A scalar after which grapheme segmentation needs no earlier context, and
before which the boundary depends only on the scalar to its left: a control,
CR or LF, or a scalar with no grapheme, Indic or pictographic property.
*/
bool graphemeSync(dchar scalar) @safe pure nothrow @nogc
{
    alias G = GraphemeBreakClass;
    const p = unicodeCoreProperties(scalar);
    if (p.grapheme == G.control || p.grapheme == G.cr || p.grapheme == G.lf)
        return true;
    return p.grapheme == G.other && !p.extendedPictographic
        && p.indic == IndicConjunctBreakClass.none;
}

/**
The same for words: no UAX #29 word rule reads past a token of these classes
to its left, none joins one to its right (WB5–WB16 need a letter, number,
quote, middle or regional indicator), and the parity of regional indicators
restarts after it.
*/
bool wordSync(WB c) @safe pure nothrow @nogc
    => c == WB.other || wordNewline(c) || c == WB.wSegSpace;

/// Word boundary before a synchronisation token `right`, given the token left of it.
bool wordBoundaryBeforeSync(dchar left, dchar right) @safe pure nothrow @nogc
{
    const l = wordBreakClass(left);
    const r = wordBreakClass(right);
    if (l == WB.cr && r == WB.lf)
        return false; // WB3
    if (wordNewline(l) || wordNewline(r))
        return true; // WB3a, WB3b
    if (l == WB.zwj && unicodeProperty(right, UnicodeProperty.ExtPict))
        return false; // WB3c
    if (l == WB.wSegSpace && r == WB.wSegSpace)
        return false; // WB3d
    return true; // WB4–WB16 cannot join a synchronisation token to its left
}

bool graphemeBoundaryBeforeSync(dchar left, dchar right) @safe pure nothrow @nogc
{
    GraphemeBreakState state;
    state.push(left);
    return state.push(right);
}

/// One token the walker consumed, and which boundaries its start is.
struct Step
{
    Token token;
    bool grapheme;
    bool word;
}

/**
Forward segmentation from a synchronisation point, one token per `advance`.
With `words`, it also runs the UAX #29 word rules, mirroring
`sparkles.base.text.boundaries.wordBoundaries` token by token.
*/
struct Walker(S, bool words)
{
    Reader!S reader;
    size_t position;
    GraphemeBreakState graphemes;
    static if (words)
    {
        WB rawLeft;
        WB left;
        WB before;
        bool haveLeft;
        bool oddRegional;
    }

    /// Continue after synchronisation token `t`.
    void startAfter(Token t) scope
    {
        graphemes.reset();
        graphemes.push(t.scalar);
        static if (words)
        {
            rawLeft = left = wordBreakClass(t.scalar);
            before = WB.other;
            haveLeft = true;
            oddRegional = false;
        }
        position = t.end;
    }

    bool atEnd() const scope => position == reader.length;

    Step advance() scope
    in (!atEnd)
    {
        const t = reader.decode(position);
        const sot = position == 0;
        Step step = Step(t, graphemes.push(t.scalar), true);
        static if (words)
        {
            const right = wordBreakClass(t.scalar);
            if (!sot)
                step.word = wordBoundary(t, right);
            rawLeft = right;
            if (!wordIgnored(right))
            {
                oddRegional = right == WB.regionalIndicator ? !oddRegional : false;
                before = haveLeft ? left : WB.other;
                left = right;
                haveLeft = true;
            }
        }
        position = t.end;
        return step;
    }

    static if (words)
    {
        /// The class of the first token after `from` that WB4 does not absorb.
        WB nextUnignored(size_t from) scope
        {
            while (from < reader.length)
            {
                const t = reader.decode(from);
                const c = wordBreakClass(t.scalar);
                if (!wordIgnored(c))
                    return c;
                from = t.end;
            }
            return WB.other;
        }

        bool wordBoundary(Token t, WB right) scope
        {
            if (rawLeft == WB.cr && right == WB.lf) return false; // WB3
            if (wordNewline(rawLeft) || wordNewline(right)) return true; // WB3a, WB3b
            if (rawLeft == WB.zwj && unicodeProperty(t.scalar, UnicodeProperty.ExtPict))
                return false; // WB3c
            if (rawLeft == WB.wSegSpace && right == WB.wSegSpace) return false; // WB3d
            if (wordIgnored(right)) return false; // WB4
            if (!haveLeft) return true;
            if (letter(left) && letter(right)) return false; // WB5
            if (letter(left) && letterMiddle(right) && letter(nextUnignored(t.end)))
                return false; // WB6
            if (letter(before) && letterMiddle(left) && letter(right)) return false; // WB7
            if (left == WB.hebrewLetter && right == WB.singleQuote) return false; // WB7a
            if (left == WB.hebrewLetter && right == WB.doubleQuote
                && nextUnignored(t.end) == WB.hebrewLetter) return false; // WB7b
            if (before == WB.hebrewLetter && left == WB.doubleQuote
                && right == WB.hebrewLetter) return false; // WB7c
            if (left == WB.numeric && right == WB.numeric) return false; // WB8
            if (letter(left) && right == WB.numeric) return false; // WB9
            if (left == WB.numeric && letter(right)) return false; // WB10
            if (before == WB.numeric && numericMiddle(left) && right == WB.numeric)
                return false; // WB11
            if (left == WB.numeric && numericMiddle(right)
                && nextUnignored(t.end) == WB.numeric) return false; // WB12
            if (left == WB.katakana && right == WB.katakana) return false; // WB13
            if ((extendedWord(left) || left == WB.extendNumLet) && right == WB.extendNumLet)
                return false; // WB13a
            if (left == WB.extendNumLet && extendedWord(right)) return false; // WB13b
            if (left == WB.regionalIndicator && right == WB.regionalIndicator && oddRegional)
                return false; // WB15, WB16
            return true; // WB999
        }
    }
}

/**
Walk back from `limit` (a token start) to the latest synchronisation token
whose start is a boundary of the walked kind and satisfies `accept`, at or
before `limit`, or strictly before it when `strict`. The walker resumes after
that token; `from` receives the token's start, or 0 when the walk reached the
source start, in which case the walker resumes at 0.
*/
Walker!(S, words) resync(bool words, alias accept = anyScalar, S)(
    Reader!S r, size_t limit, bool strict, out size_t from, out bool synced)
{
    auto walker = Walker!(S, words)(r);
    if (limit == 0)
        return walker;
    size_t q = !strict && limit < r.length ? limit : r.tokenStartBefore(limit);
    while (q != 0)
    {
        const t = r.decode(q);
        if (accept(t.scalar) && graphemeSync(t.scalar)
            && (!words || wordSync(wordBreakClass(t.scalar))))
        {
            const left = r.decode(r.tokenStartBefore(q)).scalar;
            if (graphemeBoundaryBeforeSync(left, t.scalar)
                && (!words || wordBoundaryBeforeSync(left, t.scalar)))
            {
                walker.startAfter(t);
                from = q;
                synced = true;
                return walker;
            }
        }
        q = r.tokenStartBefore(q);
    }
    return walker;
}

size_t seekNextImpl(bool words, S)(ref S source, size_t at)
in (at <= source.length, "offset is past the source end")
{
    auto r = reader(source);
    const a = r.tokenStart(at);
    if (a == r.length)
        return a;
    size_t from;
    bool synced;
    auto walker = resync!words(r, a, false, from, synced);
    while (!walker.atEnd)
    {
        const step = walker.advance();
        if (step.token.start > a && step.grapheme && step.word)
            return step.token.start;
    }
    return r.length;
}

size_t seekPreviousImpl(bool words, S)(ref S source, size_t at)
in (at <= source.length, "offset is past the source end")
{
    auto r = reader(source);
    const a = r.tokenStart(at);
    size_t last;
    bool synced;
    auto walker = resync!words(r, a, true, last, synced);
    while (walker.position < a)
    {
        const step = walker.advance();
        if (step.grapheme && step.word)
            last = step.token.start;
    }
    return last;
}


// Partial instantiation goes through a nested template: `seekNext!true.seek`.
template seekNext(bool words)
{
    size_t seek(S)(ref S source, size_t at) => seekNextImpl!words(source, at);
}

template seekPrevious(bool words)
{
    size_t seek(S)(ref S source, size_t at) => seekPreviousImpl!words(source, at);
}

template segmentAround(bool backward)
{
    WordSegment seek(S)(ref S source, size_t at) => segmentAroundImpl!backward(source, at);
}
bool isBoundaryImpl(S)(ref S source, size_t at)
in (at <= source.length, "offset is past the source end")
{
    if (at == 0 || at == source.length)
        return true;
    auto r = reader(source);
    if (r.tokenStart(at) != at)
        return false;
    return seekNextImpl!false(source, seekPreviousImpl!false(source, at)) == at;
}

/// Accumulates the kind of a word segment from its scalars.
struct KindOf
{
    bool word;
    bool blank = true;

    void add(dchar scalar) scope @safe pure nothrow @nogc
    {
        alias C = GeneralCategory;
        switch (unicodeCoreProperties(scalar).category)
        {
        case C.Lu, C.Ll, C.Lt, C.Lm, C.Lo, C.Nd, C.Nl, C.No, C.Pc:
            word = true;
            break;
        default:
            break;
        }
        blank = blank && unicodeProperty(scalar, UnicodeProperty.WSpace);
    }

    WordSegmentKind kind() const scope @safe pure nothrow @nogc
        => word ? WordSegmentKind.word : blank ? WordSegmentKind.space : WordSegmentKind.other;
}

/// The segment `[a, b)` around `at`: `a` the last segment boundary at or
/// before `at` (strictly before when `backward`), `b` the next one after `a`.
WordSegment segmentAroundImpl(bool backward, S)(ref S source, size_t at)
in (at <= source.length, "offset is past the source end")
{
    auto r = reader(source);
    const a = r.tokenStart(at);
    if (backward ? a == 0 : a == r.length)
        return WordSegment(a, a, WordSegmentKind.space);
    size_t start;
    bool synced;
    auto walker = resync!true(r, a, backward, start, synced);
    KindOf kind;
    if (synced)
        kind.add(r.decode(start).scalar);
    while (!walker.atEnd)
    {
        const step = walker.advance();
        if (step.grapheme && step.word)
        {
            if (backward ? step.token.start < a : step.token.start <= a)
            {
                start = step.token.start;
                kind = KindOf.init;
            }
            else
                return WordSegment(start, step.token.start, kind.kind);
        }
        kind.add(step.token.scalar);
    }
    return WordSegment(start, r.length, kind.kind);
}

bool whiteSpace(dchar c) @safe pure nothrow @nogc => unicodeProperty(c, UnicodeProperty.WSpace);

// A named default, not a lambda: DMD does not emit a default lambda argument
// for instantiations in another package, and the link fails.
bool anyScalar(dchar) @safe pure nothrow @nogc => true;

UnicodeSourceSpan nextBlankImpl(S)(ref S source, size_t at)
in (at <= source.length, "offset is past the source end")
{
    auto r = reader(source);
    const a = r.tokenStart(at);
    size_t from;
    bool synced;
    // A blank grapheme's start bounds every run that can hold `a`.
    auto walker = resync!(false, whiteSpace)(r, a, false, from, synced);
    bool inRun;
    size_t runStart;
    while (!walker.atEnd)
    {
        const step = walker.advance();
        if (!step.grapheme)
            continue;
        const blank = whiteSpace(step.token.scalar);
        if (inRun && blank)
        {
            if (step.token.start > a)
                return UnicodeSourceSpan(runStart, step.token.start);
            inRun = false;
        }
        else if (!inRun && !blank)
        {
            inRun = true;
            runStart = step.token.start;
        }
    }
    if (inRun && r.length > a)
        return UnicodeSourceSpan(runStart, r.length);
    return UnicodeSourceSpan(r.length, r.length);
}

UnicodeSourceSpan previousBlankImpl(S)(ref S source, size_t at)
in (at <= source.length, "offset is past the source end")
{
    auto r = reader(source);
    size_t limit = r.tokenStart(at);
    while (limit != 0)
    {
        size_t from;
        bool synced;
        auto walker = resync!(false, whiteSpace)(r, limit, true, from, synced);
        bool inRun;
        bool found;
        size_t runStart;
        size_t runEnd;
        while (!walker.atEnd)
        {
            const step = walker.advance();
            if (!step.grapheme)
                continue;
            const blank = whiteSpace(step.token.scalar);
            if (step.token.start >= limit)
            {
                if (!found || !inRun)
                    break;
                if (blank)
                    return UnicodeSourceSpan(runStart, step.token.start);
                continue;
            }
            if (inRun && blank)
            {
                inRun = false;
                runEnd = step.token.start;
            }
            else if (!inRun && !blank)
            {
                inRun = found = true;
                runStart = step.token.start;
            }
        }
        if (found)
            return UnicodeSourceSpan(runStart, inRun ? r.length : runEnd);
        // Everything in [from, limit) is blank: look further back.
        limit = from;
    }
    return UnicodeSourceSpan(0, 0);
}

version (unittest)
{
    import sparkles.base.text.boundaries : WordBoundaryWorkspace, wordBoundaries;
    import sparkles.base.text.grapheme : GraphemeSpan, GraphemeStream, scanGraphemeStream;
    import sparkles.base.text.unicode_algorithm : UnicodeBoundary, UnicodeBoundaryKind;
    import sparkles.base.text.unicode_tables : generalCategory;
    import sparkles.base.text.utf : UtfStatus, UtfToken, UtfTokenKind;

    enum maxSource = 64;

    /// Whole-source answers, computed by the batch segmenters.
    struct Oracle
    {
        size_t length;
        bool[maxSource + 1] tokenStart;
        bool[maxSource + 1] grapheme;
        bool[maxSource + 1] segment;
        dchar[maxSource + 1] scalarAt;

        this(scope const(char)[] s) @safe pure nothrow @nogc
        {
            assert(s.length <= maxSource);
            length = s.length;
            UtfToken[maxSource] tokens;
            size_t n;
            for (size_t i; i < s.length;)
            {
                const d = decodeToken(s[i .. $], UtfMode.replacement);
                tokens[n++] = UtfToken(kind: UtfTokenKind.scalar, scalar: d.token.scalar,
                    start: i, end: i + d.result.consumed);
                tokenStart[i] = true;
                scalarAt[i] = d.token.scalar;
                i += d.result.consumed;
            }
            tokenStart[length] = true;

            GraphemeStream stream;
            stream.reset(UtfMode.replacement);
            GraphemeSpan[maxSource] spans;
            const scanned = scanGraphemeStream(stream, s, spans[], true);
            assert(scanned.status == UtfStatus.end);
            foreach (span; spans[0 .. scanned.written])
                grapheme[span.start] = true;
            grapheme[length] = true;

            UnicodeBoundary[maxSource + 1] words;
            WordBoundaryWorkspace[maxSource] workspace;
            assert(wordBoundaries(tokens[0 .. n], words[], workspace[]).succeeded());
            foreach (b; words[0 .. n + 1])
                segment[b.offset] = grapheme[b.offset] && b.kind == UnicodeBoundaryKind.allowed;
            segment[0] = segment[length] = true;
        }

        size_t tokenStartOf(size_t at) const @safe pure nothrow @nogc
        {
            while (!tokenStart[at]) --at;
            return at;
        }

        size_t next(scope const(bool)[] set, size_t a) const @safe pure nothrow @nogc
        {
            foreach (i; a + 1 .. length + 1)
                if (set[i]) return i;
            return length;
        }

        size_t previous(scope const(bool)[] set, size_t a) const @safe pure nothrow @nogc
        {
            foreach_reverse (i; 0 .. a)
                if (set[i]) return i;
            return 0;
        }

        /// Classified independently of `KindOf`, from General_Category directly.
        WordSegmentKind kind(size_t start, size_t end) const @safe pure nothrow @nogc
        {
            bool word;
            bool blank = true;
            foreach (i; start .. end)
            {
                if (!tokenStart[i]) continue;
                const c = generalCategory(scalarAt[i]);
                word = word || (c >= GeneralCategory.Ll && c <= GeneralCategory.Lu
                    && c != GeneralCategory.LC) || (c >= GeneralCategory.Nd
                    && c <= GeneralCategory.No) || c == GeneralCategory.Pc;
                blank = blank && unicodeProperty(scalarAt[i], UnicodeProperty.WSpace);
            }
            return word ? WordSegmentKind.word
                : blank ? WordSegmentKind.space : WordSegmentKind.other;
        }

        bool blankAt(size_t graphemeStart) const @safe pure nothrow @nogc
            => unicodeProperty(scalarAt[graphemeStart], UnicodeProperty.WSpace);

        /// Every maximal run of non-blank graphemes, in order.
        size_t runs(ref UnicodeSourceSpan[maxSource] output) const @safe pure nothrow @nogc
        {
            size_t count;
            bool inRun;
            foreach (i; 0 .. length + 1)
            {
                if (!grapheme[i]) continue;
                const blank = i == length || blankAt(i);
                if (inRun && blank)
                {
                    output[count - 1].end = i;
                    inRun = false;
                }
                else if (!inRun && !blank)
                {
                    output[count++] = UnicodeSourceSpan(i, i);
                    inRun = true;
                }
            }
            return count;
        }
    }

    /// The bytes of a source cut at caller-chosen offsets.
    struct PartitionSource
    {
        const(char)[] bytes;
        size_t[maxSource + 1] ends;
        size_t count;

        size_t length() const scope @safe pure nothrow @nogc => bytes.length;

        SourceChunk chunkAt(size_t offset) const return scope @safe pure nothrow @nogc
        {
            size_t start;
            foreach (end; ends[0 .. count])
            {
                if (offset < end)
                    return SourceChunk(start, bytes[start .. end]);
                start = end;
            }
            assert(0, "offset is outside the source");
        }
    }

    struct Xorshift
    {
        ulong state;
        uint next(uint bound) @safe pure nothrow @nogc
        {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            return cast(uint)(state % bound);
        }
    }

    void checkAgainstOracle(S)(ref S source, scope ref const Oracle o)
    {
        UnicodeSourceSpan[maxSource] runs;
        const runCount = o.runs(runs);
        foreach (at; 0 .. o.length + 1)
        {
            const a = o.tokenStartOf(at);
            assert(nextGraphemeBoundary(source, at) == (a == o.length ? a : o.next(o.grapheme[], a)));
            assert(previousGraphemeBoundary(source, at) == o.previous(o.grapheme[], a));
            assert(isGraphemeBoundary(source, at) == (o.tokenStart[at] && o.grapheme[at]));

            const forward = nextWordSegment(source, at);
            if (a == o.length)
                assert(forward == WordSegment(a, a, WordSegmentKind.space));
            else
            {
                const start = o.segment[a] ? a : o.previous(o.segment[], a);
                const end = o.next(o.segment[], start);
                assert(forward == WordSegment(start, end, o.kind(start, end)));
            }
            const backward = previousWordSegment(source, at);
            if (a == 0)
                assert(backward == WordSegment(0, 0, WordSegmentKind.space));
            else
            {
                const start = o.previous(o.segment[], a);
                const end = o.next(o.segment[], start);
                assert(backward == WordSegment(start, end, o.kind(start, end)));
            }

            auto nextRun = UnicodeSourceSpan(o.length, o.length);
            foreach (run; runs[0 .. runCount])
                if (run.end > a)
                {
                    nextRun = run;
                    break;
                }
            assert(nextBlankDelimited(source, at) == nextRun);
            auto previousRun = UnicodeSourceSpan(0, 0);
            foreach (run; runs[0 .. runCount])
                if (run.start < a)
                    previousRun = run;
            assert(previousBlankDelimited(source, at) == previousRun);
        }
    }

    void checkPartitions(scope const(char)[] text, ref Xorshift random, size_t randomCuts)
        @safe pure nothrow @nogc
    {
        const o = Oracle(text);
        checkAgainstOracle(text, o);
        foreach (width; 1 .. 5)
        {
            auto source = PartitionSource(text);
            for (size_t end = width; ; end += width)
            {
                source.ends[source.count++] = end < text.length ? end : text.length;
                if (end >= text.length) break;
            }
            checkAgainstOracle(source, o);
        }
        foreach (_; 0 .. randomCuts)
        {
            auto source = PartitionSource(text);
            for (size_t end = 1 + random.next(4); ; end += 1 + random.next(4))
            {
                source.ends[source.count++] = end < text.length ? end : text.length;
                if (end >= text.length) break;
            }
            checkAgainstOracle(source, o);
        }
    }

    static immutable string[] pieces = [
        "a", "Z", "7", "0", " ", "\t", "\r\n", "\r", "\n", "'", ".", ",", ":", "_",
        "\"", "!", "­", "́", "̈", "‍", " ", "　",
        "\U0001F469", "\U0001F4BB", "❤", "️", "\U0001F3FB",
        "\U0001F1FA", "\U0001F1F8", "\U0001F1E6", "क", "्", "ा",
        "؀", "א", "ב", "ア", "ᄀ", "ᅡ", "ᆨ",
        "\xC0", "\x80", "\xE0\xA0", "\xF0\x9F", "\xED\xA0\x80", "ก",
    ];
}

/// Fixed sources reach the hard cases in every 1–4 byte chunking.
@("seek.oracle.fixedSources")
@safe pure nothrow @nogc
unittest
{
    static immutable string[] sources = [
        "",
        "a",
        "\U0001F1FA\U0001F1F8\U0001F1E6\U0001F1E7\U0001F1E8",
        "x\U0001F1FA\U0001F1F8\U0001F1E6 \U0001F1E7\U0001F1E8\U0001F1E9",
        "\U0001F469‍\U0001F4BB́‍❤️",
        "क्क्́क का",
        "a\r\n\r\r\n\nb",
        "can't stop, 3.14 1,000 א\"ב א'",
        "\xC0́\x80\x80\x80\x80a\xE0\xA0b\xF0\x9F",
        "؀a ؀؀ ́́x",
        "foo_barアア a­b",
        "각ᄀ กก",
        "  \t　 ",
    ];
    auto random = Xorshift(0x9E3779B97F4A7C15);
    foreach (text; sources)
        checkPartitions(text, random, 4);
}

/// Random sources over the piece alphabet; a failure prints nothing in
/// `@nogc`, so the seed and index live in the loop for a debugger.
@("seek.oracle.generatedSources")
@safe pure nothrow @nogc
unittest
{
    auto random = Xorshift(0xD1B54A32D192ED03);
    char[maxSource] buffer;
    foreach (iteration; 0 .. 300)
    {
        size_t length;
        foreach (_; 0 .. 1 + random.next(16))
        {
            const piece = pieces[random.next(cast(uint) pieces.length)];
            if (length + piece.length > 40) break;
            buffer[length .. length + piece.length] = piece;
            length += piece.length;
        }
        checkPartitions(buffer[0 .. length], random, 2);
    }
}

/// Resuming at the nearest token without resynchronising gets flag parity wrong.
@("seek.grapheme.resynchronisationIsNeeded")
@safe pure nothrow @nogc
unittest
{
    enum flags = "\U0001F1FA\U0001F1F8\U0001F1E6\U0001F1E7\U0001F1E8";
    size_t naivePrevious(size_t at)
    {
        auto source = SliceSource(flags);
        auto r = reader(source);
        return r.tokenStartBefore(at); // a fresh state calls every token a cluster start
    }
    assert(previousGraphemeBoundary(flags, 16) == 8);
    assert(naivePrevious(16) != 8);
    assert(previousGraphemeBoundary(flags, 20) == 16);
    assert(nextGraphemeBoundary(flags, 4) == 8);
}

/// Every White_Space scalar synchronises, so blank runs resync at their edges.
@("seek.blankDelimited.whiteSpaceSynchronises")
@safe pure nothrow @nogc
unittest
{
    foreach (dchar c; 0 .. 0x3001)
        if (unicodeProperty(c, UnicodeProperty.WSpace))
            assert(graphemeSync(c), "a White_Space scalar must synchronise");
}

/// A long run without synchronisation tokens is walked once, not per query.
@("seek.grapheme.longRegionalRun")
@safe pure nothrow @nogc
unittest
{
    static immutable char[4 * 1001] flags = () {
        char[4 * 1001] result;
        foreach (i; 0 .. 1001)
            result[i * 4 .. i * 4 + 4] = i % 2 ? "\U0001F1F8" : "\U0001F1FA";
        return result;
    }();
    assert(previousGraphemeBoundary(flags[], flags.length) == flags.length - 4);
    assert(nextGraphemeBoundary(flags[], flags.length - 8) == flags.length - 4);
    assert(!isGraphemeBoundary(flags[], flags.length - 8));
}
