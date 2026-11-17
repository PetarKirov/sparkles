/**
Code-editor presentation facts (`EAP5`): the bracket matching the caret, the
trailing whitespace a line carries, and the caret's line and column. Each is
a pure, bounded query over the retained text, so a view can ask once per
frame without owning a scan.

Brackets are matched by bytes, not by syntax: a bracket inside a string or
comment counts like any other. The scan stops after `limit` bytes, and a
bracket whose partner lies further away reports as unmatched only when the
whole text was scanned.
*/
module sparkles.ui.editor.presentation;

import sparkles.text_buffer.text : Text;

@safe:

/// The bracket next to a caret and its partner.
struct BracketMatch
{
    /// The bracket at or before the caret; `size_t.max` without one.
    size_t bracket = size_t.max;
    /// Its partner; `size_t.max` when none was found.
    size_t partner = size_t.max;
    /// The scan ended at its limit before deciding.
    bool undecided;

    /// A bracket stands next to the caret.
    bool found() const scope pure nothrow @nogc => bracket != size_t.max;
    /// The bracket has a partner.
    bool matched() const scope pure nothrow @nogc => partner != size_t.max;
}

private char partnerOf(char c) pure nothrow @nogc
{
    switch (c)
    {
        case '(': return ')';
        case ')': return '(';
        case '[': return ']';
        case ']': return '[';
        case '{': return '}';
        case '}': return '{';
        default: return 0;
    }
}

private bool opening(char c) pure nothrow @nogc => c == '(' || c == '[' || c == '{';

/**
The bracket at `caret` (preferred) or just before it, and its partner found by
nesting depth within `limit` bytes.
*/
BracketMatch matchingBracket(in Text text, size_t caret, size_t limit = 1 << 16) pure nothrow @nogc
{
    BracketMatch result;
    if (caret < text.length && partnerOf(text.byteAt(caret)))
        result.bracket = caret;
    else if (caret > 0 && caret <= text.length && partnerOf(text.byteAt(caret - 1)))
        result.bracket = caret - 1;
    else
        return result;
    const self = text.byteAt(result.bracket);
    const other = partnerOf(self);
    size_t depth = 1, scanned;
    if (opening(self))
    {
        for (size_t at = result.bracket + 1; at < text.length; ++at)
        {
            if (++scanned > limit) { result.undecided = true; return result; }
            const c = text.byteAt(at);
            if (c == self) ++depth;
            else if (c == other && --depth == 0) { result.partner = at; return result; }
        }
    }
    else
    {
        for (size_t at = result.bracket; at-- > 0;)
        {
            if (++scanned > limit) { result.undecided = true; return result; }
            const c = text.byteAt(at);
            if (c == self) ++depth;
            else if (c == other && --depth == 0) { result.partner = at; return result; }
        }
    }
    return result;
}

/// Nesting decides the partner, from either side and either direction.
@("editor.presentation.matchingBracket")
@safe pure nothrow unittest
{
    const text = Text("f(a[1], (b)) {");
    assert(matchingBracket(text, 1).partner == 11);
    assert(matchingBracket(text, 12).partner == 1); // just after `)`
    assert(matchingBracket(text, 3).partner == 5);
    assert(matchingBracket(text, 0).found == false);
    const open = matchingBracket(text, 13);
    assert(open.found && !open.matched && !open.undecided);
    const far = matchingBracket(Text("(" ~ "x".repeat(100) ~ ")"), 0, 10);
    assert(far.found && !far.matched && far.undecided);
}

version (unittest) private string repeat(string s, size_t n) pure nothrow
{
    string r;
    foreach (_; 0 .. n) r ~= s;
    return r;
}

/**
The trailing spaces and tabs of `line` as `[start, end)`; empty (`start ==
end`) when there are none. A line of only whitespace is all trailing.
*/
size_t[2] trailingWhitespace(in Text text, size_t line) pure nothrow @nogc
{
    const start = text.lineStart(line);
    size_t end = text.lineEnd(line);
    if (end > start && text.byteAt(end - 1) == '\r') --end; // a CRLF's CR is the break
    size_t from = end;
    while (from > start && (text.byteAt(from - 1) == ' ' || text.byteAt(from - 1) == '\t')) --from;
    return [from, end];
}

/// Only the run before the break; CRLF's carriage return is not whitespace here.
@("editor.presentation.trailingWhitespace")
@safe pure nothrow unittest
{
    const text = Text("a b  \nclean\n \t\r\nx\t");
    assert(trailingWhitespace(text, 0) == [3, 5]);
    const clean = trailingWhitespace(text, 1);
    assert(clean[0] == clean[1]);
    assert(trailingWhitespace(text, 2) == [12, 14]);
    assert(trailingWhitespace(text, 3) == [17, 18]);
}

/**
The caret's line and column as a status line reads them: both 1-based, the
column counted in grapheme clusters from the line start. The column is
recounted only when the text or the caret moved, so a steady frame on a long
line walks nothing.
*/
struct CaretPosition
{
    /// The 1-based line and grapheme column of the last `refresh`.
    size_t line = 1, column = 1;

    private Text counted;
    private size_t head = size_t.max;

    /// Recount for the caret at byte `caret` of `text`, when either changed.
    void refresh(in Text text, size_t caret) pure nothrow @nogc
    {
        import sparkles.base.buffer : UniqueBuffer;
        import sparkles.base.text.seek : nextGraphemeBoundary;
        if (caret == head && text == counted) return;
        const at = caret < text.length ? caret : text.length;
        const index = text.lineOf(at);
        const start = text.lineStart(index);
        UniqueBuffer!(char, 256) bytes;
        bytes.length = at - start;
        text.copyTo(start, at, bytes[]);
        size_t clusters = 1;
        for (size_t i = 0; i < bytes.length; i = nextGraphemeBoundary(bytes[], i))
            ++clusters;
        line = index + 1;
        column = clusters;
        counted = Text(text);
        head = caret;
    }
}

/// Columns count grapheme clusters, not bytes; the count follows the caret.
@("editor.presentation.caretPosition")
@safe pure nothrow @nogc unittest
{
    const text = Text("ab\néx");
    CaretPosition position;
    position.refresh(text, 0);
    assert(position.line == 1 && position.column == 1);
    position.refresh(text, 2);
    assert(position.line == 1 && position.column == 3);
    position.refresh(text, 6);
    assert(position.line == 2 && position.column == 2, "e + combining acute is one cluster");
    position.refresh(text, 7);
    assert(position.column == 3);
}
