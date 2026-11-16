/**
Search and replace over the editor's text (`EDS1`–`EDS6`).

A $(LREF SearchQuery) says what to look for: a literal or a regular
expression, case-sensitive or folded, anywhere or as a whole word.
$(LREF SearchPattern.compile) checks it once and reports a pattern it cannot
run as an `error`, never as an exception. $(LREF findMatches) then scans the
persistent `Text` from any offset under a $(LREF SearchBudget), so a host
can search a large document a slice at a time and stay responsive; the
navigation, selection and replacement functions build on it.

Every replacement goes through the editor's own commit path, as one
revision of its history: one `undo` restores the text and the ranges from
before it. A match that would change a protected span is left alone and
counted.

$(B Bounds.) A literal scan is a Knuth–Morris–Pratt pass over the text's
scalars, linear in the bytes scanned. Regular expressions use `std.regex`,
whose Thompson (parallel-NFA) engine runs in time linear in the input for
a fixed pattern; it switches to its backtracking engine only for
backreferences, which are refused here, so every accepted pattern runs in
O(bytes × pattern). Patterns are limited to $(LREF maxPatternLength) bytes
and their counted repetitions to $(LREF maxRepetitionWork) expanded copies,
which bounds the compiled program.

Specification: `docs/specs/ui/editor.md` §9.
*/
module sparkles.ui.editor.search;

import core.time : MonoTime;

import std.regex : Regex, matchAll, regex;

import sparkles.base.text.seek : isGraphemeBoundary, nextWordSegment, previousWordSegment;
import sparkles.base.text.unicode_tables : simpleCaseFold;
import sparkles.text_buffer.change_set : Edit;
import sparkles.text_buffer.summary : Affinity, tokenAt;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.effect : EditEffects;
import sparkles.ui.editor.field : EditorField;
import sparkles.ui.editor.selection : EditRange;
import sparkles.ui.editor.state : EditorState;
import sparkles.ui.editor.step : replaceSpansInPlace, selectRangesInPlace;

/// The longest pattern `SearchPattern.compile` accepts, in bytes.
enum size_t maxPatternLength = 4096;

/**
The most copies a regular expression's counted repetitions may expand to:
the product of every `{n}`/`{n,m}` bound in the pattern. `std.regex` unrolls
counted repetitions, so this bounds the compiled program, and with it the
work per byte.
*/
enum size_t maxRepetitionWork = 100_000;

/// What to search for (`EDS1`).
struct SearchQuery
{
    /// The text to find, or a `std.regex` pattern when `regex` is set.
    string pattern;
    /// `pattern` is a regular expression; `^` and `$` match at line ends.
    bool regex;
    /// Match case exactly; otherwise compare Unicode simple case folds.
    bool caseSensitive;
    /// Only matches that start and end on default UAX #29 word boundaries.
    bool wholeWord;
}

/**
How much one call may do (`EDS5`): it stops after `maxMatches` matches or
once it has scanned `maxBytes` bytes, and says where to resume. Each call
makes progress, so resuming always terminates.
*/
struct SearchBudget
{
    /// The most matches one call reports; 0 counts as 1.
    size_t maxMatches = 10_000;
    /// The most bytes one call scans; 0 counts as 1. A regular-expression
    /// call scans whole lines, so it may exceed this by the rest of a line.
    size_t maxBytes = 4 << 20;

    /// No limit: one call scans to the end of the text.
    enum SearchBudget unbounded = SearchBudget(size_t.max, size_t.max);
}

/// A match: the bytes `[start, end)` of the text, both grapheme boundaries.
struct MatchRange
{
    size_t start;
    size_t end;

    /// The match is empty, as a regular expression's may be.
    bool empty() const scope @safe pure nothrow @nogc => start == end;
}

/**
A checked query, ready to run (`EDS2`). An invalid one carries an `error`
and matches nothing; compile once per query, not once per call.
*/
struct SearchPattern
{
    /// The query it was compiled from.
    SearchQuery query;
    /// Why the query cannot run, or empty.
    string error;

    private dchar[] needle; // the literal's scalars, folded unless case-sensitive
    private size_t[] failure; // its Knuth–Morris–Pratt failure function
    private Regex!char program;

    /// Whether the query can run.
    bool valid() const scope @safe pure nothrow @nogc => error.length == 0;

    /// Whether it can match anything: an invalid query or an empty pattern
    /// matches nothing.
    bool matchesNothing() const scope @safe pure nothrow @nogc
        => !valid || query.pattern.length == 0;

    /**
    Check and compile `query`. A pattern longer than $(LREF maxPatternLength),
    a regular expression `std.regex` rejects, one with a backreference (which
    would need a backtracking matcher) or one whose counted repetitions
    exceed $(LREF maxRepetitionWork) gives a pattern with an `error`.
    */
    static SearchPattern compile(SearchQuery query) @safe nothrow
    {
        SearchPattern p;
        p.query = query;
        if (query.pattern.length > maxPatternLength)
        {
            p.error = "the pattern is longer than the 4096 bytes a search accepts";
            return p;
        }
        if (!query.regex)
        {
            p.compileLiteral();
            return p;
        }
        if (const problem = unboundedConstruct(query.pattern))
        {
            p.error = problem;
            return p;
        }
        try
            p.program = regex(lineStartsRewritten(query.pattern),
                query.caseSensitive ? "m" : "mi");
        catch (Exception e)
            p.error = e.msg.length ? e.msg : "invalid regular expression";
        return p;
    }

    private void compileLiteral() @safe pure nothrow
    {
        const bytes = query.pattern;
        for (size_t i; i < bytes.length;)
        {
            const token = tokenAt(bytes[i .. $]);
            needle ~= query.caseSensitive ? token.scalar : simpleCaseFold(token.scalar);
            i += token.length;
        }
        failure = new size_t[needle.length];
        for (size_t i = 1, k = 0; i < needle.length; ++i)
        {
            while (k && needle[i] != needle[k])
                k = failure[k - 1];
            if (needle[i] == needle[k])
                ++k;
            failure[i] = k;
        }
    }
}

///
@("editor.search.compile")
@safe nothrow
unittest
{
    assert(SearchPattern.compile(SearchQuery("a(b)", regex: true)).valid);
    assert(SearchPattern.compile(SearchQuery("a(b", regex: false)).valid, "a literal is never invalid");
    assert(!SearchPattern.compile(SearchQuery("a(b", regex: true)).valid);
    assert(!SearchPattern.compile(SearchQuery(`(a)\1`, regex: true)).valid, "no backreferences");
    assert(SearchPattern.compile(SearchQuery(`\\1`, regex: true)).valid, "an escaped backslash is not one");
    assert(!SearchPattern.compile(SearchQuery(`((a{1000}){1000})`, regex: true)).valid);
    assert(SearchPattern.compile(SearchQuery(`\d{4}-\d{2}-\d{2}`, regex: true)).valid);
    assert(SearchPattern.compile(SearchQuery("")).matchesNothing);
}

/**
What one $(LREF findMatches) call found: the matches in order, never
overlapping, and whether it stopped early. When `truncated`, a call from
`resumeAt` with the same pattern continues exactly where this one stopped,
so a run of bounded calls finds what one unbounded call would.
*/
struct SearchResult
{
    /// The matches, sorted and disjoint.
    MatchRange[] matches;
    /// The budget ran out before the end of the text.
    bool truncated;
    /// Where to resume when `truncated`.
    size_t resumeAt;
    /// The bytes this call scanned.
    size_t bytesScanned;
    /// The pattern's error, when it has one; then nothing was searched.
    string error;

    /// Whether the search ran.
    bool ok() const scope @safe pure nothrow @nogc => error.length == 0;
}

/**
The matches of `pattern` in `text` that start at or after `from`, within
`budget` (`EDS1`, `EDS5`).

Matches are leftmost and never overlap. A literal scan starts at `from`; a
regular-expression scan starts at the line holding `from`, so `^`, `\b` and
look-behind see the line, and reports the matches starting at or after
`from`. A match whose ends split a grapheme cluster is not reported, nor,
with `wholeWord`, one whose ends are not word boundaries. An empty pattern
matches nothing; a regular expression may match the empty string, and the
scan then moves on by one scalar, so it always ends.

Resuming from `resumeAt` reproduces an unbounded run, except that a
regular-expression match spanning a line break where one call's lines end
is cut at that break (a call scans whole lines).
*/
SearchResult findMatches(in Text text, const SearchPattern pattern, size_t from = 0,
    in SearchBudget budget = SearchBudget.init) @safe nothrow
{
    SearchResult result;
    if (!pattern.valid)
    {
        result.error = pattern.error;
        return result;
    }
    static struct Collect
    {
        MatchRange[] matches;
        void put(size_t start, size_t end) @safe pure nothrow { matches ~= MatchRange(start, end); }
        void put(C)(size_t start, size_t end, ref C) { put(start, end); }
    }

    Collect sink;
    const s = scan(text, pattern, from, budget, sink);
    result.matches = sink.matches;
    result.truncated = s.truncated;
    result.resumeAt = s.resumeAt;
    result.bytesScanned = s.scanned;
    return result;
}

/// ditto
SearchResult findMatches(in Text text, SearchQuery query, size_t from = 0,
    in SearchBudget budget = SearchBudget.init) @safe nothrow
    => findMatches(text, SearchPattern.compile(query), from, budget);

/// A literal, case-sensitive and not.
@("editor.search.literal")
@safe nothrow
unittest
{
    const text = Text("one two one, ONE");
    const exact = findMatches(text, SearchQuery("one", caseSensitive: true));
    assert(exact.ok && !exact.truncated);
    assert(exact.matches == [MatchRange(0, 3), MatchRange(8, 11)]);
    assert(findMatches(text, SearchQuery("one")).matches.length == 3, "folded by default");
    assert(findMatches(text, SearchQuery("one", caseSensitive: true), 1).matches == [MatchRange(8, 11)]);
    assert(findMatches(Text("aaaa"), SearchQuery("aa")).matches == [MatchRange(0, 2), MatchRange(2, 4)],
        "matches do not overlap");
}

/// Case folding is Unicode's simple folding, scalar by scalar.
@("editor.search.caseInsensitiveUnicode")
@safe nothrow
unittest
{
    const text = Text("Straße STRAẞE strasse ÄÖ äö");
    const r = findMatches(text, SearchQuery("straße"));
    assert(r.matches.length == 2, "ẞ folds to ß; ss is a full folding only");
    assert(text.slice(r.matches[1].start, r.matches[1].end) == "STRAẞE");
    assert(findMatches(text, SearchQuery("äö")).matches.length == 2);
    assert(findMatches(text, SearchQuery("äö", caseSensitive: true)).matches.length == 1);
    assert(findMatches(Text("é e"), SearchQuery("e")).matches == [MatchRange(4, 5)],
        "a match never splits a cluster");
}

/// Whole words are delimited by UAX #29 word boundaries.
@("editor.search.wholeWord")
@safe nothrow
unittest
{
    const text = Text("cat concat cat_s cat. (cat) Cat");
    const r = findMatches(text, SearchQuery("cat", wholeWord: true));
    assert(r.matches == [MatchRange(0, 3), MatchRange(17, 20), MatchRange(23, 26), MatchRange(28, 31)]);
    const re = findMatches(text, SearchQuery(`\w*cat`, regex: true, caseSensitive: true, wholeWord: true));
    assert(re.matches == [MatchRange(0, 3), MatchRange(4, 10), MatchRange(17, 20), MatchRange(23, 26)],
        "a rejected match is passed over, not shortened");
}

/// Regular expressions, with groups and line anchors.
@("editor.search.regex")
@safe nothrow
unittest
{
    const text = Text("x = 1\ny = 22\nzz");
    const r = findMatches(text, SearchQuery(`^(\w) = (\d+)$`, regex: true));
    assert(r.ok && r.matches == [MatchRange(0, 5), MatchRange(6, 12)]);
    assert(findMatches(text, SearchQuery(`Y`, regex: true)).matches == [MatchRange(6, 7)]);
    assert(findMatches(text, SearchQuery(`Y`, regex: true, caseSensitive: true)).matches.length == 0);
    assert(findMatches(text, SearchQuery(`\d+`, regex: true), 10).matches == [MatchRange(10, 12)],
        "from inside a line, the line is still seen");
}

/// An invalid pattern reports an error and searches nothing.
@("editor.search.invalidPattern")
@safe nothrow
unittest
{
    const r = findMatches(Text("(a"), SearchQuery("(a", regex: true));
    assert(!r.ok && r.error.length && r.matches.length == 0);
    auto long_ = new char[maxPatternLength + 1];
    long_[] = 'a';
    assert(!findMatches(Text("a"), SearchQuery(long_.idup)).ok);
}

/// The empty pattern matches nothing; an empty match moves on.
@("editor.search.emptyMatches")
@safe nothrow
unittest
{
    assert(findMatches(Text("abc"), SearchQuery("")).matches.length == 0);
    assert(findMatches(Text("abc"), SearchQuery("", regex: true)).matches.length == 0);
    const r = findMatches(Text("ab"), SearchQuery("x*", regex: true));
    assert(r.matches == [MatchRange(0, 0), MatchRange(1, 1), MatchRange(2, 2)]);
    const s = findMatches(Text("áb"), SearchQuery("x*", regex: true));
    assert(s.matches == [MatchRange(0, 0), MatchRange(3, 3), MatchRange(4, 4)],
        "not inside a cluster");
    const lines = findMatches(Text("a\n\nb"), SearchQuery("^", regex: true));
    assert(lines.matches == [MatchRange(0, 0), MatchRange(2, 2), MatchRange(3, 3)]);
}

/// Bounded calls resumed from `resumeAt` find what one unbounded call does.
@("editor.search.budgetResume")
@safe nothrow
unittest
{
    char[] doc;
    foreach (i; 0 .. 300)
        doc ~= i % 7 ? "a fine Line, then lines\n" : "\n";
    const text = Text(doc);
    const SearchQuery[4] queries = [SearchQuery("line"), SearchQuery("line", wholeWord: true),
        SearchQuery(`l\w+|^$`, regex: true), SearchQuery(`e*`, regex: true)];
    foreach (q; queries)
    {
        const pattern = SearchPattern.compile(q);
        const whole = findMatches(text, pattern, 0, SearchBudget.unbounded);
        assert(!whole.truncated && whole.matches.length);
        foreach (budget; [SearchBudget(1, size_t.max), SearchBudget(7, 50), SearchBudget(1000, 1)])
        {
            MatchRange[] pieces;
            size_t at, calls;
            for (;;)
            {
                const r = findMatches(text, pattern, at, budget);
                pieces ~= r.matches;
                ++calls;
                assert(r.matches.length <= budget.maxMatches);
                if (!r.truncated)
                    break;
                assert(r.resumeAt > at || r.matches.length, "every call makes progress");
                at = r.resumeAt;
            }
            assert(pieces == whole.matches);
            assert(calls > 1);
        }
    }
}

/**
A pathological pattern for backtracking engines ends in linear time: the
Thompson engine runs every alternative in step. The budget bounds what one
call reads, and backreferences, the one feature that would need
backtracking, are refused at compile time.
*/
@("editor.search.pathologicalRegex")
@safe nothrow
unittest
{
    auto doc = new char[20_000];
    doc[] = 'a';
    const text = Text(doc);
    foreach (p; [`(a*)*b`, `(a|aa)*c`, `(a|a)*b`, `(x+x+)+y`])
    {
        const r = findMatches(text, SearchQuery(p, regex: true), 0, SearchBudget(10, 1 << 16));
        assert(r.ok && r.matches.length == 0 && !r.truncated);
        assert(r.bytesScanned == doc.length);
    }
    const lines = Text("aaaa\n".repeat(5000));
    const r = findMatches(lines, SearchQuery(`(a*)*b`, regex: true), 0, SearchBudget(10, 1000));
    assert(r.truncated && r.bytesScanned <= 1005, "a call reads its budget, rounded up to a line");
}

private string repeat(string s, size_t n) @safe pure nothrow
{
    string result;
    foreach (_; 0 .. n)
        result ~= s;
    return result;
}

/// Where a search step landed (`EDS3`).
struct MatchStep
{
    /// A match was found.
    bool found;
    /// The match.
    MatchRange range;
    /// The search went past the end (or start) of the text and came round.
    bool wrapped;
    /// The pattern's error, when it has one.
    string error;
}

/**
The first match at or after `from`, wrapping to the start of the text: for
find-next, pass the end of the current match. An empty match exactly at
`from` is passed over, so a repeated find-next moves on.
*/
MatchStep nextMatch(in Text text, const SearchPattern pattern, size_t from) @safe nothrow
{
    MatchStep step;
    step.error = pattern.error;
    if (pattern.matchesNothing)
        return step;
    if (firstFrom(text, pattern, from, from, step.range))
        step.found = true;
    else if (from > 0 && firstFrom(text, pattern, 0, size_t.max, step.range))
        step.found = step.wrapped = true;
    return step;
}

// The first match at or after `from`, other than an empty one at `skipEmptyAt`.
private bool firstFrom(in Text text, const SearchPattern pattern, size_t from, size_t skipEmptyAt,
    out MatchRange found) @safe nothrow
{
    for (size_t at = from; at <= text.length;)
    {
        const r = findMatches(text, pattern, at, SearchBudget(2, SearchBudget.init.maxBytes));
        foreach (m; r.matches)
            if (!(m.empty && m.start == skipEmptyAt))
            {
                found = m;
                return true;
            }
        if (!r.truncated)
            return false;
        at = r.resumeAt;
    }
    return false;
}

/**
The last match that starts before `before`, wrapping to the end of the
text: for find-previous, pass the start of the current match. It scans from
the start of the text.
*/
MatchStep previousMatch(in Text text, const SearchPattern pattern, size_t before) @safe nothrow
{
    MatchStep step;
    step.error = pattern.error;
    if (pattern.matchesNothing)
        return step;
    static struct Last
    {
        size_t before;
        bool found, foundBefore;
        MatchRange last, lastBefore;
        void put(size_t start, size_t end) @safe pure nothrow @nogc
        {
            found = true;
            last = MatchRange(start, end);
            if (start < before)
            {
                foundBefore = true;
                lastBefore = last;
            }
        }
        void put(C)(size_t start, size_t end, ref C) { put(start, end); }
    }

    auto sink = Last(before);
    cast(void) scan(text, pattern, 0, SearchBudget.unbounded, sink);
    if (sink.foundBefore)
    {
        step.found = true;
        step.range = sink.lastBefore;
    }
    else if (sink.found)
    {
        step.found = step.wrapped = true;
        step.range = sink.last;
    }
    return step;
}

/// Find-next and find-previous, wrapping.
@("editor.search.nextAndPrevious")
@safe nothrow
unittest
{
    const text = Text("ab ab ab");
    const p = SearchPattern.compile(SearchQuery("ab"));
    assert(nextMatch(text, p, 0) == MatchStep(true, MatchRange(0, 2)));
    assert(nextMatch(text, p, 2) == MatchStep(true, MatchRange(3, 5)));
    assert(nextMatch(text, p, 7) == MatchStep(true, MatchRange(0, 2), true));
    assert(previousMatch(text, p, 6) == MatchStep(true, MatchRange(3, 5)));
    assert(previousMatch(text, p, 0) == MatchStep(true, MatchRange(6, 8), true));
    assert(!nextMatch(text, SearchPattern.compile(SearchQuery("zz")), 3).found);

    const empty = SearchPattern.compile(SearchQuery("^", regex: true));
    const lines = Text("a\nb");
    assert(nextMatch(lines, empty, 0).range == MatchRange(2, 2), "an empty match at from is passed over");
    assert(nextMatch(lines, empty, 2) == MatchStep(true, MatchRange(0, 0), true));
    assert(nextMatch(lines, SearchPattern.compile(SearchQuery("(", regex: true)), 0).error.length);
}

/**
Select every match (`EDS3`): one range per match, the primary being the
first match that holds or follows the old primary range's start, or the first match.
With no match, or an invalid pattern, the selection is left as it was. The
result is the search's, so a caller sees whether `budget` truncated it.
*/
SearchResult selectAllMatches(ref EditorState state, const SearchPattern pattern,
    in SearchBudget budget = SearchBudget.unbounded, MonoTime now = MonoTime.init) @safe nothrow
{
    auto r = findMatches(state.text, pattern, 0, budget);
    if (!r.ok || r.matches.length == 0)
        return r;
    auto ranges = new EditRange[r.matches.length];
    const origin = state.selection.primary.start;
    size_t primary = size_t.max;
    foreach (i, m; r.matches)
    {
        ranges[i] = EditRange(m.start, m.end);
        if (primary == size_t.max && (m.end > origin || m.start >= origin))
            primary = i;
    }
    cast(void) selectRangesInPlace(state, ranges, primary == size_t.max ? 0 : primary, now);
    return r;
}

/// ditto
SearchResult selectAllMatches(ref EditorField field, const SearchPattern pattern,
    in SearchBudget budget = SearchBudget.unbounded) @safe nothrow
    => selectAllMatches(field.state, pattern, budget, field.context.now);

///
@("editor.search.selectAllMatches")
@safe nothrow
unittest
{
    import sparkles.ui.editor.testing : parse, show;

    auto state = parse("one two ON|E one");
    const r = selectAllMatches(state, SearchPattern.compile(SearchQuery("one")));
    assert(r.matches.length == 3);
    assert(show(state) == "[one] two [ONE] [one]");
    assert(state.selection.primaryIndex == 1, "the match at the primary stays primary");
    cast(void) selectAllMatches(state, SearchPattern.compile(SearchQuery("zzz")));
    assert(show(state) == "[one] two [ONE] [one]", "no match leaves the selection");
}

/**
Select `match` as the one range, forward (`EDS3`). Returns false, changing
nothing, when it is not within the text.
*/
bool selectMatch(ref EditorState state, MatchRange match, MonoTime now = MonoTime.init)
    @safe pure nothrow @nogc
{
    if (match.start > match.end || match.end > state.text.length)
        return false;
    const EditRange[1] range = [EditRange(match.start, match.end)];
    cast(void) selectRangesInPlace(state, range[], 0, now);
    return true;
}

///
@("editor.search.selectMatch")
@safe pure nothrow
unittest
{
    import sparkles.ui.editor.testing : parse, show;

    auto state = parse("a|b cd");
    assert(selectMatch(state, MatchRange(3, 5)) && show(state) == "ab [cd]");
    assert(!selectMatch(state, MatchRange(3, 9)) && show(state) == "ab [cd]");
}

/**
Select the next match after the primary range (`direction` > 0) or the
previous one before it, wrapping: find-next and find-previous on a state.
*/
MatchStep selectNextMatch(ref EditorState state, const SearchPattern pattern, int direction = 1,
    MonoTime now = MonoTime.init) @safe nothrow
{
    const primary = state.selection.primary;
    const step = direction >= 0 ? nextMatch(state.text, pattern, primary.end)
        : previousMatch(state.text, pattern, primary.start);
    if (step.found)
        cast(void) selectMatch(state, step.range, now);
    return step;
}

///
@("editor.search.selectNextMatch")
@safe nothrow
unittest
{
    import sparkles.ui.editor.testing : parse, show;

    auto state = parse("|x1 x2 x3");
    const p = SearchPattern.compile(SearchQuery(`x\d`, regex: true));
    selectNextMatch(state, p);
    assert(show(state) == "[x1] x2 x3");
    selectNextMatch(state, p);
    selectNextMatch(state, p);
    assert(show(state) == "x1 x2 [x3]");
    assert(selectNextMatch(state, p).wrapped && show(state) == "[x1] x2 x3");
    assert(selectNextMatch(state, p, -1).wrapped && show(state) == "x1 x2 [x3]");
}

/// What a replacement did (`EDS4`).
struct ReplaceResult
{
    /// Matches replaced.
    size_t replaced;
    /// Matches left alone because they would change a protected span.
    size_t skippedProtected;
    /// The budget ran out: matches from `resumeAt` were not replaced.
    bool truncated;
    /// Where the search stopped when `truncated`, in the text before the
    /// replacement.
    size_t resumeAt;
    /// The pattern's error, when it has one; then the text is unchanged.
    string error;
    /// The match selected after `replaceCurrent`.
    MatchStep next;
    /// The step's effects: `changed` with the change set, and
    /// `rejectedReadOnly` when a match was skipped.
    EditEffects effects;

    /// Whether the replacement ran.
    bool ok() const scope @safe pure nothrow @nogc => error.length == 0;
}

/**
Replace every match of `pattern` with `replacement` as one revision of the
history (`EDS4`): one `undo` restores the text and the ranges, which are
otherwise carried through the change. A regular expression's replacement
may name its groups: `$&` or `$0` is the whole match, `$1`–`$9` or `${n}` a
group, and `$$` a dollar sign; a literal's replacement is taken as is.
Matches that would change a protected span are skipped and counted. With
an invalid pattern the text is unchanged and the result has its `error`.
*/
ReplaceResult replaceAll(ref EditorState state, const SearchPattern pattern,
    scope const(char)[] replacement, in SearchBudget budget = SearchBudget.unbounded,
    MonoTime now = MonoTime.init) @safe nothrow
{
    ReplaceResult result;
    result.error = pattern.error;
    if (pattern.matchesNothing)
        return result;
    auto sink = Replacements(pattern.query.regex, replacement.idup, Text(replacement));
    const s = scan(state.text, pattern, 0, budget, sink);
    result.truncated = s.truncated;
    result.resumeAt = s.resumeAt;
    if (sink.edits.length == 0)
        return result;
    size_t skipped;
    result.effects = replaceSpansInPlace(state, sink.edits, now, skipped);
    result.skippedProtected = skipped;
    result.replaced = sink.edits.length - skipped;
    return result;
}

/// ditto
ReplaceResult replaceAll(ref EditorField field, const SearchPattern pattern,
    scope const(char)[] replacement, in SearchBudget budget = SearchBudget.unbounded) @safe nothrow
    => replaceAll(field.state, pattern, replacement, budget, field.context.now);

/// One undo step restores the exact text, and the ranges.
@("editor.search.replaceAllIsOneUndo")
@safe nothrow
unittest
{
    import sparkles.ui.editor.command : EditCommand, EditKind;

    auto field = EditorField.make("cat, Cat and CAT");
    const before = field.state.selection;
    const r = replaceAll(field, SearchPattern.compile(SearchQuery("cat")), "dog");
    assert(r.ok && r.replaced == 3 && r.skippedProtected == 0);
    assert(field.text == "dog, dog and dog");
    field.run(EditCommand.of(EditKind.undo));
    assert(field.text == "cat, Cat and CAT" && field.state.selection == before);
    field.run(EditCommand.of(EditKind.redo));
    assert(field.text == "dog, dog and dog");
}

/// Groups in a regular expression's replacement.
@("editor.search.replaceWithGroups")
@safe nothrow
unittest
{
    auto field = EditorField.make("x = 1\ny = 22");
    const p = SearchPattern.compile(SearchQuery(`^(\w) = (\d+)$`, regex: true));
    assert(replaceAll(field, p, "$2 => ${1} ($&) $$ $9 $").replaced == 2);
    assert(field.text == "1 => x (x = 1) $  $\n22 => y (y = 22) $  $");

    auto literal = EditorField.make("a.b");
    replaceAll(literal, SearchPattern.compile(SearchQuery(".")), "$&");
    assert(literal.text == "a$&b", "a literal's replacement is literal");

    auto empties = EditorField.make("ab");
    replaceAll(empties, SearchPattern.compile(SearchQuery("x*", regex: true)), "-");
    assert(empties.text == "-a-b-");
}

/// An invalid pattern leaves the text, and the history, alone.
@("editor.search.invalidPatternChangesNothing")
@safe nothrow
unittest
{
    import sparkles.ui.editor.command : EditCommand, EditKind;
    import sparkles.ui.editor.effect : EffectKind, NoopReason;

    auto field = EditorField.make("a(b");
    const r = replaceAll(field, SearchPattern.compile(SearchQuery("a(", regex: true)), "x");
    assert(!r.ok && r.replaced == 0 && field.text == "a(b");
    const undo = field.run(EditCommand.of(EditKind.undo));
    assert(undo.effects.first(EffectKind.noop).reason == NoopReason.nothingToUndo);
}

/// Matches overlapping a protected span are skipped and counted.
@("editor.search.protectedSpansSkipped")
@safe nothrow
unittest
{
    import sparkles.ui.editor.effect : EffectKind;
    import sparkles.ui.editor.state : ReadOnlySpan;

    auto state = EditorState.create("ab [ab] ab");
    state.readOnly.put(ReadOnlySpan(3, 7));
    const r = replaceAll(state, SearchPattern.compile(SearchQuery("ab")), "X");
    assert(r.replaced == 2 && r.skippedProtected == 1);
    assert(r.effects.has(EffectKind.rejectedReadOnly));
    assert(state.text == "X [ab] X");
    assert(state.readOnly[][0] == ReadOnlySpan(2, 6), "the span follows the text");
}

/**
Replace the match the primary range selects, then select the next match
(`EDS4`): find-and-replace one at a time. When the primary range is not
exactly a match, nothing is replaced and the next match from its start is
selected. The replacement is one revision of the history; a protected
match is skipped and counted, and the next match selected.
*/
ReplaceResult replaceCurrent(ref EditorState state, const SearchPattern pattern,
    scope const(char)[] replacement, MonoTime now = MonoTime.init) @safe nothrow
{
    ReplaceResult result;
    result.error = pattern.error;
    if (pattern.matchesNothing)
        return result;
    const primary = state.selection.primary;
    auto sink = Replacements(pattern.query.regex, replacement.idup, Text(replacement));
    cast(void) scan(state.text, pattern, primary.start, SearchBudget(1, size_t.max), sink);
    const current = sink.edits.length && sink.edits[0].from == primary.start
        && sink.edits[0].to == primary.end;
    size_t resumeFrom = primary.start;
    if (current)
    {
        size_t skipped;
        result.effects = replaceSpansInPlace(state, sink.edits[0 .. 1], now, skipped);
        result.skippedProtected = skipped;
        result.replaced = 1 - skipped;
        resumeFrom = skipped ? primary.end : primary.start + sink.edits[0].inserted.length;
    }
    result.next = nextMatch(state.text, pattern, resumeFrom);
    if (result.next.found)
        cast(void) selectMatch(state, result.next.range, now);
    return result;
}

/// ditto
ReplaceResult replaceCurrent(ref EditorField field, const SearchPattern pattern,
    scope const(char)[] replacement) @safe nothrow
    => replaceCurrent(field.state, pattern, replacement, field.context.now);

///
@("editor.search.replaceCurrent")
@safe nothrow
unittest
{
    import sparkles.ui.editor.command : EditCommand, EditKind;
    import sparkles.ui.editor.testing : show;

    auto field = EditorField.make("a1 a2 a3");
    field.state.selection = typeof(field.state.selection).caret(0);
    const p = SearchPattern.compile(SearchQuery(`a(\d)`, regex: true));
    auto r = replaceCurrent(field, p, "b$1");
    assert(r.replaced == 0 && show(field.state) == "[a1] a2 a3", "a caret first selects");
    r = replaceCurrent(field, p, "b$1");
    assert(r.replaced == 1 && show(field.state) == "b1 [a2] a3");
    r = replaceCurrent(field, p, "b$1");
    assert(r.replaced == 1 && show(field.state) == "b1 b2 [a3]");
    field.run(EditCommand.of(EditKind.undo));
    assert(show(field.state) == "b1 [a2] a3", "each replacement is its own undo step");
}

// ---------------------------------------------------------------- scanning

private:

/// What a scan did.
struct Scan
{
    size_t count;
    bool truncated;
    size_t resumeAt;
    size_t scanned;
}

/// A sink that builds each match's replacement edit.
struct Replacements
{
    bool expand;
    string replacement;
    Text literal;
    Edit[] edits;

    void put(size_t start, size_t end) @safe pure nothrow
    {
        edits ~= Edit(start, end, literal);
    }

    void put(C)(size_t start, size_t end, ref C captures)
    {
        if (!expand)
            return put(start, end);
        char[] text;
        expandReplacement(replacement, captures, text);
        edits ~= Edit(start, end, Text(text));
    }
}

/// `replacement` with `$&`, `$0`–`$9`, `${n}` and `$$` resolved against
/// `captures`; a group that did not take part, or does not exist, is empty.
void expandReplacement(C)(scope const(char)[] replacement, ref C captures, ref char[] output)
{
    void group(size_t n)
    {
        if (n < captures.length)
            output ~= captures[n];
    }

    for (size_t i; i < replacement.length; ++i)
    {
        const c = replacement[i];
        if (c != '$' || i + 1 == replacement.length)
        {
            output ~= c;
            continue;
        }
        const d = replacement[i + 1];
        if (d == '$')
        {
            output ~= '$';
            ++i;
        }
        else if (d == '&')
        {
            group(0);
            ++i;
        }
        else if (d >= '0' && d <= '9')
        {
            group(d - '0');
            ++i;
        }
        else if (d == '{')
        {
            size_t j = i + 2, n;
            while (j < replacement.length && replacement[j] >= '0' && replacement[j] <= '9'
                && n < 1000)
                n = n * 10 + (replacement[j++] - '0');
            if (j < replacement.length && replacement[j] == '}' && j > i + 2)
            {
                group(n);
                i = j;
            }
            else
                output ~= c;
        }
        else
            output ~= c;
    }
}

/// Whether `[start, end)` may be reported: grapheme-aligned and, for a
/// whole-word query, delimited by word boundaries.
bool acceptable(in Text text, in SearchPattern pattern, size_t start, size_t end)
    @safe pure nothrow @nogc
{
    if (!isGraphemeBoundary(text, start) || !isGraphemeBoundary(text, end))
        return false;
    if (!pattern.query.wholeWord)
        return true;
    return nextWordSegment(text, start).start == start
        && previousWordSegment(text, end).end == end;
}

/// Feed the matches of `pattern` from `from` to `sink`, within `budget`.
Scan scan(Sink)(in Text text, ref const SearchPattern pattern, size_t from, in SearchBudget budget,
    ref Sink sink)
{
    if (pattern.matchesNothing)
        return Scan.init;
    if (from > text.length)
        from = text.length;
    const maxMatches = budget.maxMatches ? budget.maxMatches : 1;
    const maxBytes = budget.maxBytes ? budget.maxBytes : 1;
    return pattern.query.regex ? scanRegex(text, pattern, from, maxMatches, maxBytes, sink)
        : scanLiteral(text, pattern, text.snap(from, Affinity.after).value, maxMatches,
            maxBytes, sink);
}

/// Knuth–Morris–Pratt over the text's scalars, folded like the needle.
Scan scanLiteral(Sink)(in Text text, ref const SearchPattern pattern, size_t from, size_t maxMatches,
    size_t maxBytes, ref Sink sink)
{
    Scan s;
    const needle = pattern.needle;
    const fail = pattern.failure;
    const m = needle.length;
    const fold = !pattern.query.caseSensitive;
    // The byte offset of each of the last `m` scalars, by scalar index mod m.
    auto starts = new size_t[m];
    size_t index, matched;
    foreach (chunk; text.chunks(from))
    {
        const bytes = chunk.bytes;
        size_t i = from > chunk.start ? from - chunk.start : 0;
        while (i < bytes.length)
        {
            const at = chunk.start + i;
            const partial = matched ? starts[(index - matched) % m] : at;
            if (at - from >= maxBytes && partial > from)
            {
                s.truncated = true;
                s.resumeAt = partial;
                s.scanned = at - from;
                return s;
            }
            const token = tokenAt(bytes[i .. $]);
            const c = fold ? simpleCaseFold(token.scalar) : token.scalar;
            starts[index % m] = at;
            ++index;
            i += token.length;
            while (matched && c != needle[matched])
                matched = fail[matched - 1];
            if (c == needle[matched])
                ++matched;
            if (matched < m)
                continue;
            const start = starts[(index - m) % m];
            const end = at + token.length;
            if (!acceptable(text, pattern, start, end))
            {
                matched = fail[m - 1];
                continue;
            }
            sink.put(start, end);
            matched = 0;
            if (++s.count == maxMatches)
            {
                s.truncated = end < text.length;
                s.resumeAt = end;
                s.scanned = end - from;
                return s;
            }
        }
    }
    s.scanned = text.length - from;
    return s;
}

/**
`std.regex` over whole lines: from the start of the line holding `from` to
the end of the line holding `from + maxBytes`, copied out of the text.
*/
Scan scanRegex(Sink)(in Text text, ref const SearchPattern pattern, size_t from, size_t maxMatches,
    size_t maxBytes, ref Sink sink)
{
    Scan s;
    const length = text.length;
    const windowStart = text.lineStart(text.lineOf(from));
    const limit = maxBytes > length - from ? length : from + maxBytes;
    size_t windowEnd = length;
    if (limit < length)
    {
        const line = text.lineOf(limit);
        if (line + 1 < text.lineCount)
            windowEnd = text.lineStart(line + 1);
    }
    auto window = new char[windowEnd - windowStart];
    text.copyTo(windowStart, windowEnd, window);
    s.scanned = window.length;
    const last = windowEnd == length;
    try
    {
        foreach (m; matchAll(window, pattern.program))
        {
            const start = windowStart + m.pre.length;
            const end = start + m.hit.length;
            if (!last && start >= windowEnd)
                break; // the next window's
            if (start < from || !acceptable(text, pattern, start, end))
                continue;
            sink.put(start, end, m);
            if (++s.count == maxMatches)
            {
                // After an empty match the engine moves on by one scalar.
                s.resumeAt = end > start ? end
                    : start < length ? start + tokenAt(window[start - windowStart .. $]).length
                    : length + 1;
                s.truncated = s.resumeAt <= length;
                return s;
            }
        }
    }
    catch (Exception)
    {
        // `std.regex` reports no matching errors; a defensive stop.
        return s;
    }
    if (!last)
    {
        s.truncated = true;
        s.resumeAt = windowEnd;
    }
    return s;
}

/**
`pattern` with each line-start anchor `^` outside a class spelled as
look-behind: the start of the input or just after a line feed.

`std.regex`'s multi-line `^` tests the character at the position rather
than the one before it, so it also matches just before a line feed
(`^\n` matches `ab\ncd` at 2); the look-behind form is exact.
*/
string lineStartsRewritten(string pattern) @safe pure nothrow
{
    enum lineStart = `(?:(?<![\s\S])|(?<=\n))`;
    string result;
    size_t copied;
    bool inClass;
    for (size_t i; i < pattern.length; ++i)
    {
        const c = pattern[i];
        if (c == '\\')
        {
            ++i;
            continue;
        }
        if (inClass)
        {
            inClass = c != ']';
            continue;
        }
        if (c == '[')
        {
            inClass = true;
            if (i + 1 < pattern.length && pattern[i + 1] == '^')
                ++i;
            if (i + 1 < pattern.length && pattern[i + 1] == ']')
                ++i;
            continue;
        }
        if (c != '^')
            continue;
        result ~= pattern[copied .. i];
        result ~= lineStart;
        copied = i + 1;
    }
    return copied ? result ~ pattern[copied .. $] : pattern;
}

@("editor.search.lineStartAnchor")
@safe nothrow
unittest
{
    assert(lineStartsRewritten(`a[^^]\^b`) == `a[^^]\^b`);
    assert(lineStartsRewritten(`^a|^b`) == `(?:(?<![\s\S])|(?<=\n))a|(?:(?<![\s\S])|(?<=\n))b`);
    assert(findMatches(Text("ab\ncd"), SearchQuery(`^\n`, regex: true)).matches.length == 0);
    assert(findMatches(Text("ab\n\ncd"), SearchQuery(`^\n`, regex: true)).matches == [MatchRange(3, 4)]);
    assert(findMatches(Text("a\n\nb"), SearchQuery(`^$`, regex: true)).matches == [MatchRange(2, 2)]);
}

/**
Why a regular expression cannot run within the bounds, or `null`: a
backreference outside a class, or counted repetitions whose bounds multiply
past `maxRepetitionWork`.
*/
string unboundedConstruct(scope const(char)[] pattern) @safe pure nothrow @nogc
{
    bool inClass;
    size_t work = 1;
    for (size_t i; i < pattern.length; ++i)
    {
        const c = pattern[i];
        if (c == '\\' && i + 1 < pattern.length)
        {
            const d = pattern[++i];
            if (!inClass && d >= '1' && d <= '9')
                return "backreferences are not supported: they need a backtracking matcher";
            continue;
        }
        if (inClass)
        {
            inClass = c != ']';
            continue;
        }
        if (c == '[')
        {
            inClass = true;
            // A `]` first in a class is a member.
            if (i + 1 < pattern.length && pattern[i + 1] == ']')
                ++i;
            else if (i + 2 < pattern.length && pattern[i + 1] == '^' && pattern[i + 2] == ']')
                i += 2;
            continue;
        }
        if (c != '{')
            continue;
        size_t bound, n;
        size_t j = i + 1;
        for (; j < pattern.length; ++j)
        {
            const d = pattern[j];
            if (d >= '0' && d <= '9')
            {
                n = n > maxRepetitionWork ? n : n * 10 + (d - '0');
                continue;
            }
            bound = n > bound ? n : bound;
            n = 0;
            if (d != ',')
                break;
        }
        if (j < pattern.length && pattern[j] == '}')
        {
            work *= bound > 1 ? bound : 1;
            if (work > maxRepetitionWork)
                return "the pattern's counted repetitions expand past 100000 copies";
            i = j;
        }
    }
    return null;
}
