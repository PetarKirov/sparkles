/**
In-document search: **one matcher, every canvas**.

hue used to search twice — the window scanned the whole source with
`std.string.indexOf`, case-sensitively, producing byte-precise matches; the
terminal tested each laid-out row with an ASCII case-insensitive scan, producing
a boolean. A user searching `Foo` got different answers depending on which
backend was painting, and nothing in either spec said they should agree.

That is the defect [`UIA13`](../../../../docs/specs/hue/ui-architecture.md)
now names: a divergence between backends is a defect, not a variation. The fix is
structural rather than careful — the matcher lives here, above the canvas seam,
so there is no second implementation to drift.

The engine is a pure function over borrowed text: it neither owns the document
nor knows what will be painted, which is the same shape `sparkles:diff` and
`sparkles:dsv` hold. Navigation state — the current match, the scroll anchor —
belongs to the caller.

$(B Not yet `@nogc`.) `findMatches` allocates its result, matching the behaviour
it replaces. Making the search allocation-free is a real improvement and a
separate change; doing it here would have mixed a defect fix with a performance
one.
*/
module sparkles.source_view.search;

import sparkles.base.text.analysis : AnalysisCase;

@safe:

/**
The monospace column width of a UTF-8 run: the number of codepoints, since each
non-continuation byte begins one.

Combining marks, wide characters and tabs each count as one column — hue's
`FNT6` rule, deliberately, and the reason this is not
`sparkles.base.text.width.codepointWidth`, which measures the width a terminal
would actually give a wide glyph. Changing this metric is a `FNT6` change, not a
search change.
*/
size_t columnWidth(scope const(char)[] run) pure nothrow @nogc
{
    size_t cols;
    foreach (ubyte c; run)
        if ((c & 0xC0) != 0x80) // not a UTF-8 continuation byte
            ++cols;
    return cols;
}

/**
A search hit: grid coordinates for drawing, plus the source byte range that is
the identity currency everything else (selection, jumps, decorations) speaks.

A match spanning a newline is clipped to its first line, so `cols` and `end`
describe one row.
*/
struct Match
{
    size_t line; /// 0-based line the match starts on
    int col; /// start column (display cells) within the line
    int cols; /// width in display cells (clipped at the line end)
    size_t start; /// source byte offset of the match
    size_t end; /// source byte end (clipped at the line end, like `cols`)
}

/**
Smart case: the one rule, in one place.

A query containing an uppercase **cased** character is matched case-sensitively;
otherwise case is folded. This is the convention every interactive search tool
converged on, and the formulation is `sparkles:fuzzy`'s — "cased scalar" rather
than merely "uppercase", so a digit or a symbol never forces sensitivity.

It lives here rather than in either backend because a case rule implemented
twice is exactly how the two searches came to disagree.
*/
AnalysisCase smartCase(scope const(char)[] query) pure nothrow
{
    import std.uni : isUpper, isLower;
    import std.utf : byDchar;

    try
    {
        foreach (dchar c; query.byDchar)
            if (c.isUpper && !c.isLower)
                return AnalysisCase.sensitive;
    }
    catch (Exception)
    {
        // Invalid UTF-8 in a query is not a reason to change the case rule.
    }
    return AnalysisCase.simpleFold;
}

/**
How a host wants matching done — the resolved form of hue's `SearchSettings`.

It exists so the policy is a **value both backends are handed**, rather than a
rule each one re-derives. `caseFor` is the only decision it makes, and it makes
it once.
*/
struct SearchPolicy
{
    /// Uppercase in the query means case-sensitive; otherwise fold.
    bool smartCase = true;

    /// Fold beyond ASCII. Off by default: a full fold can change a run's
    /// length, and `Match` promises source byte offsets.
    bool unicodeCaseFold = false;

    /// The case mode for `query` under this policy.
    AnalysisCase caseFor(scope const(char)[] query) const pure nothrow
    {
        if (!smartCase)
            return unicodeCaseFold ? AnalysisCase.fullFold : AnalysisCase.simpleFold;
        const c = smartCase_(query);
        if (c == AnalysisCase.simpleFold && unicodeCaseFold)
            return AnalysisCase.fullFold;
        return c;
    }
}

/// ASCII case fold. Non-ASCII is left alone: a full Unicode fold can change a
/// run's length, which would break the byte offsets `Match` promises.
private char foldAscii(char c) pure nothrow @nogc
    => (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;

/// Does `hay` begin with `needle` under `mode`?
/**
Whether `hay` begins with `needle` under `mode`'s case rule.

Public because the picker's grep source scans with it (`PKC1`). Grep owns
its own scan — it produces byte columns and bounded windows, and runs
`@nogc` on a worker — but it must not own its own idea of what MATCHES.
Two literal predicates is how the in-document searches came to disagree in
the first place; this is the one place that decision is made.
*/
bool startsWithFolded(scope const(char)[] hay, scope const(char)[] needle,
    AnalysisCase mode) pure nothrow @nogc
{
    if (needle.length > hay.length)
        return false;
    if (mode == AnalysisCase.sensitive)
        return hay[0 .. needle.length] == needle;
    foreach (i, char n; needle)
        if (foldAscii(hay[i]) != foldAscii(n))
            return false;
    return true;
}

/**
Every non-overlapping occurrence of `query` in `source`, mapped to grid
coordinates via `lineStarts`.

`mode` defaults to $(LREF smartCase) of the query, which is what a caller
almost always wants; pass it explicitly only to override the convention.

Complexity is `O(source.length * query.length)` — the naive scan the GUI already
performed. A literal prefilter would improve it and is deliberately not part of
this change.
*/
Match[] findMatches(scope const(char)[] source, scope const(char)[] query,
    scope const(size_t)[] lineStarts, AnalysisCase mode)
{
    import std.range : assumeSorted;

    Match[] matches;
    if (query.length == 0 || query.length > source.length)
        return matches;
    // A caller with no line index cannot be given line coordinates. This is a
    // real state — a view model whose document has not been laid out yet — and
    // it must return nothing rather than underflow the `lowerBound` below.
    if (lineStarts.length == 0)
        return matches;

    size_t from;
    while (from + query.length <= source.length)
    {
        if (!startsWithFolded(source[from .. $], query, mode))
        {
            ++from;
            continue;
        }
        const start = from;
        const line = lineStarts.assumeSorted.lowerBound(start + 1).length - 1;
        const lineStart = lineStarts[line];

        // Clip at the line end: a hit is one row, so `cols` never spans a break.
        size_t end = start + query.length;
        foreach (i; start .. end)
            if (source[i] == '\n')
            {
                end = i;
                break;
            }

        matches ~= Match(line, cast(int) columnWidth(source[lineStart .. start]),
            cast(int) columnWidth(source[start .. end]), start, end);
        from = start + query.length;
    }
    return matches;
}

/// ditto
Match[] findMatches(scope const(char)[] source, scope const(char)[] query,
    scope const(size_t)[] lineStarts)
    => findMatches(source, query, lineStarts, smartCase(query));

/// ditto
private alias smartCase_ = smartCase;

/// The number of display lines in `source`, matching `byStyledLine`'s line
/// indexing: one per `\n`, plus a final line for trailing content. A trailing
/// newline does not add an empty last line; empty source is zero lines. Drives
/// viewport clamping, the gutter, and the scrollbar.
size_t lineCount(scope const(char)[] source) pure nothrow @nogc
{
    if (source.length == 0)
        return 0;
    size_t n;
    foreach (c; source)
        if (c == '\n')
            ++n;
    if (source[$ - 1] != '\n')
        ++n;
    return n;
}

/// Byte offset where each display line starts (line 0 at 0, then after each
/// `\n`). Sorted ascending, so a byte offset's line is a binary search away.
size_t[] buildLineStarts(scope const(char)[] source) pure nothrow
{
    size_t[] starts = [0];
    foreach (i, c; source)
        if (c == '\n')
            starts ~= i + 1;
    return starts;
}

@("source_view.search.smartCaseFollowsTheQuery")
@safe unittest
{
    assert(smartCase("foo") == AnalysisCase.simpleFold);
    assert(smartCase("Foo") == AnalysisCase.sensitive);
    assert(smartCase("foo123") == AnalysisCase.simpleFold, "digits are not cased");
    assert(smartCase("foo_bar!") == AnalysisCase.simpleFold, "symbols are not cased");
    assert(smartCase("") == AnalysisCase.simpleFold);
}

@("source_view.search.findMatchesLocatesAndMaps")
@safe unittest
{
    const src = "ab\n  abc\nx"; // line 0 "ab", line 1 "  abc", line 2 "x"
    const ls = buildLineStarts(src);
    const m = findMatches(src, "ab", ls, AnalysisCase.sensitive);
    assert(m.length == 2);
    assert(m[0] == Match(0, 0, 2, 0, 2));
    assert(m[1] == Match(1, 2, 2, 5, 7));
}

@("source_view.search.oneCaseRuleForBothBackends")
@safe unittest
{
    // The regression this module exists to prevent: the window used to find
    // one of these and the terminal the other.
    const src = "Foo foo FOO";
    const ls = buildLineStarts(src);

    // A lowercase query folds — all three.
    assert(findMatches(src, "foo", ls).length == 3);
    // A query with an uppercase cased character does not.
    assert(findMatches(src, "Foo", ls).length == 1);
    assert(findMatches(src, "FOO", ls).length == 1);
}

@("source_view.search.matchesNeverSpanALineBreak")
@safe unittest
{
    const src = "ab\ncd";
    const ls = buildLineStarts(src);
    // The query straddles the newline; the reported span stops at it, so a
    // caller painting `cols` cells on one row cannot overrun.
    const m = findMatches(src, "b\nc", ls, AnalysisCase.sensitive);
    assert(m.length == 1);
    assert(m[0].line == 0 && m[0].start == 1 && m[0].end == 2);
}

@("source_view.search.noLineIndexFindsNothing")
@safe unittest
{
    // Regression: `lowerBound(...).length - 1` underflows on an empty index,
    // which a view model has before its document is laid out.
    assert(findMatches("abc", "b", null).length == 0);
}

@("source_view.search.emptyAndOversizedQueriesFindNothing")
@safe unittest
{
    const src = "abc";
    const ls = buildLineStarts(src);
    assert(findMatches(src, "", ls).length == 0);
    assert(findMatches(src, "abcd", ls).length == 0);
}
