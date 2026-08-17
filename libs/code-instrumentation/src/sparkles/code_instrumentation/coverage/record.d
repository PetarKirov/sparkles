/**
Line- and field-oriented scanning shared by the textual coverage formats.

DMD `.lst`, gcov and LCOV are all records of the same shape — a line, split
once on a delimiter, sometimes split again into comma-separated fields, with
numeric fields in fixed positions. Each parser used to do that itself, and
each did it slightly differently: three copies of a "sum the digits, ignore
everything else" number reader, which is how a `geninfo --checksum` line
(`DA:1,3,f1ab29d0`) came to report an execution count of 31290. A field that
is not entirely digits is malformed, and saying so once is what keeps that
class of bug from coming back.

Failures travel as $(REF ParseExpected, sparkles,base,text,errors) — the
repository's parse-error vocabulary — carrying a byte offset into the artifact
so a caller can point at the record that went wrong.

Everything here is `@safe pure nothrow @nogc`: the scanner borrows its input
and allocates nothing.
*/
module sparkles.code_instrumentation.coverage.record;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.base.text.readers : readInteger;
import sparkles.test_runner.attributes : betterC;

@safe pure nothrow @nogc:

/**
Walks `input` one line at a time, tracking each line's byte offset.

Handles both line endings and a missing final terminator, so a `.lst` written
on Windows and one written without a trailing newline scan identically:
---
auto scanner = RecordScanner(contents);
while (scanner.next)
    parseRecord(scanner.line, scanner.offset);
---
*/
struct RecordScanner
{
    private const(char)[] _input;
    private size_t _cursor;   // byte offset of the next unread line
    private size_t _offset;   // byte offset of the current line
    private const(char)[] _line;

    /**
    Begins scanning `input`. The scanner borrows it; no copy is made.

    `input` is deliberately not `scope`. A record's fields are handed to
    `splitFields`, which writes them into a caller-supplied buffer, and
    dip1000 will not let a `scope` slice be stored there. Relaxing it is
    sound because nothing downstream retains a borrow: the parsers `idup`
    every string they keep (`sourcePath`, `functionName`) and the rest of the
    model is plain numbers, so no part of a finished `CoverageReport` points
    back into the artifact text.
    */
    this(const(char)[] input) @safe pure nothrow @nogc
    {
        _input = input;
    }

    /**
    Advances to the next line.

    Returns: `true` when a line was read, `false` at end of input.
    */
    bool next() @safe pure nothrow @nogc
    {
        if (_cursor >= _input.length)
        {
            _line = null;
            return false;
        }

        _offset = _cursor;
        size_t end = _cursor;
        while (end < _input.length && _input[end] != '\n')
            end++;

        // The line excludes its terminator, and a CRLF file must not leave a
        // stray '\r' on the end of every field.
        size_t textEnd = end;
        if (textEnd > _cursor && _input[textEnd - 1] == '\r')
            textEnd--;

        _line = _input[_cursor .. textEnd];
        _cursor = end < _input.length ? end + 1 : _input.length;
        return true;
    }

    /// The current line, without its terminator.
    const(char)[] line() const @safe pure nothrow @nogc => _line;

    /// Byte offset of the current line's first character. A field's own
    /// offset is this plus its index within $(LREF line) — the parsers track
    /// that as they split, which keeps this `@safe` (pointer arithmetic
    /// between two slices is not).
    size_t offset() const @safe pure nothrow @nogc => _offset;
}

/// ASCII whitespace, the only kind these formats pad numeric columns with.
private bool isSpace(char c) => c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '\v';

/// `s` without leading or trailing ASCII whitespace, as a borrowed slice.
const(char)[] trimmed(const(char)[] s)
{
    size_t start;
    size_t end = s.length;
    while (start < end && isSpace(s[start]))
        start++;
    while (end > start && isSpace(s[end - 1]))
        end--;
    return s[start .. end];
}

/// The two halves of a record split at a delimiter, plus whether the
/// delimiter was there at all.
struct Halves
{
    const(char)[] before; /// text preceding the separator (all of it when absent)
    const(char)[] after;  /// text following the separator (empty when absent)
    bool found;           /// whether the separator was present
    size_t afterIndex;    /// index of `after` within the input, for offsets
}

/**
Splits `s` at the first `separator`.

Returned by value rather than through `out` parameters: an `out` parameter
does not inherit the input's `return scope`, so dip1000 rejects handing a
borrowed slice back that way.

Params:
    s = the record to split
    separator = the delimiter to split at

Returns: the $(LREF Halves) of the split.
*/
Halves splitOnce(const(char)[] s, char separator)
{
    foreach (i, c; s)
        if (c == separator)
            return Halves(s[0 .. i], s[i + 1 .. $], true, i + 1);
    return Halves(s, s[$ .. $], false, s.length);
}

/**
Splits `s` on `separator` into `fields`, without allocating.

Writes at most `fields.length` fields; a record with more fields than that
puts everything remaining, separators included, in the last slot — which is
what LCOV's `FN:<start>,<end>,<name>` needs, since a function name may itself
contain commas.

When `starts` is given, `starts[i]` receives field `i`'s index within `s`, so
a caller can report an error against the offending character rather than the
record it sat in.

Returns: the number of slots written.
*/
// `s` is deliberately not `scope` (its slices are stored into `fields`),
// while `fields` and `starts` are (they are the caller's stack buffers).
size_t splitFields(const(char)[] s, char separator, scope const(char)[][] fields,
    scope size_t[] starts = null)
{
    if (fields.length == 0)
        return 0;

    size_t count;
    size_t start;
    foreach (i, c; s)
    {
        if (c != separator)
            continue;
        if (count + 1 == fields.length)
            break;              // the last slot keeps the whole remainder
        if (count < starts.length)
            starts[count] = start;
        fields[count++] = s[start .. i];
        start = i + 1;
    }
    if (count < starts.length)
        starts[count] = start;
    fields[count++] = s[start .. $];
    return count;
}

/**
Reads `field` as an unsigned integer, requiring it to be *entirely* digits.

This is the difference that matters: the hand-rolled readers these parsers
used to carry skipped any character that was not a digit and kept going, so
`3,f1ab29d0` read as 31290 rather than being rejected. Surrounding whitespace
is allowed (the formats right-align their counters); anything else is not.

Params:
    field = the text to read
    offset = byte offset of `field` within the artifact, for error reporting

Returns: the value, or `unexpectedCharacter` / `emptyInput` /
    `numericOverflow`.
*/
ParseExpected!ulong wholeNumber(scope const(char)[] field, size_t offset)
{
    size_t lead;
    while (lead < field.length && isSpace(field[lead]))
        lead++;

    auto digits = field.trimmed;
    if (digits.length == 0)
        return parseErr!ulong(ParseErrorCode.emptyInput, offset);

    auto cursor = digits;
    auto parsed = readInteger!ulong(cursor);
    if (!parsed)
        return parseErr!ulong(parsed.error.code, offset + lead + parsed.error.offset);
    if (cursor.length != 0)
        return parseErr!ulong(ParseErrorCode.unexpectedCharacter,
            offset + lead + (digits.length - cursor.length),
            "expected digits only");
    return parseOk(parsed.value);
}

@("coverage.record.scannerLineEndings")
@betterC
unittest
{
    // LF, CRLF and a missing final terminator all scan the same, and each
    // line reports the byte offset the artifact actually has.
    auto lf = RecordScanner("a\nbb\nccc");
    assert(lf.next && lf.line == "a" && lf.offset == 0);
    assert(lf.next && lf.line == "bb" && lf.offset == 2);
    assert(lf.next && lf.line == "ccc" && lf.offset == 5);
    assert(!lf.next);

    auto crlf = RecordScanner("a\r\nbb\r\n");
    assert(crlf.next && crlf.line == "a");
    assert(crlf.next && crlf.line == "bb");
    assert(!crlf.next);

    auto empty = RecordScanner("");
    assert(!empty.next);

    // A blank line is a line, not the end of input.
    auto blank = RecordScanner("\n\nx");
    assert(blank.next && blank.line == "");
    assert(blank.next && blank.line == "");
    assert(blank.next && blank.line == "x");
    assert(!blank.next);
}

@("coverage.record.splitOnce")
@betterC
unittest
{
    // Only the *first* separator splits: a gcov source line may contain any
    // number of further colons.
    const split = splitOnce("   1:  42:  return a ? b : c;", ':');
    assert(split.found);
    assert(split.before == "   1");
    assert(split.after == "  42:  return a ? b : c;");
    assert(split.afterIndex == 5);

    const none = splitOnce("no separator here", ':');
    assert(!none.found);
    assert(none.before == "no separator here");
    assert(none.after.length == 0);
}

@("coverage.record.splitFields")
@betterC
unittest
{
    const(char)[][4] fields;

    assert(splitFields("1,3,f1ab29d0", ',', fields[]) == 3);
    assert(fields[0] == "1" && fields[1] == "3" && fields[2] == "f1ab29d0");

    // More fields than slots: the last slot keeps the remainder verbatim, so
    // a function name containing commas survives intact.
    const(char)[][3] three;
    assert(splitFields("10,20,do,Work", ',', three[]) == 3);
    assert(three[0] == "10" && three[1] == "20" && three[2] == "do,Work");

    // A single field with no separator is still one field.
    assert(splitFields("solo", ',', fields[]) == 1);
    assert(fields[0] == "solo");

    // Field positions, for pointing a diagnostic at the right character.
    size_t[4] starts;
    assert(splitFields("1,3,f1ab", ',', fields[], starts[]) == 3);
    assert(starts[0] == 0 && starts[1] == 2 && starts[2] == 4);
}

@("coverage.record.wholeNumberRejectsTrailingJunk")
@betterC
unittest
{
    import sparkles.base.text.errors : ParseErrorCode;

    // The bug this exists to prevent: an LCOV checksum after the count.
    assert(wholeNumber("3", 0).value == 3);
    assert(wholeNumber("      5", 0).value == 5);   // right-aligned .lst column
    assert(wholeNumber("0000000", 0).value == 0);   // -cov's uncovered marker

    auto checksum = wholeNumber("3,f1ab29d0", 0);
    assert(checksum.hasError);
    assert(checksum.error.code == ParseErrorCode.unexpectedCharacter);

    assert(wholeNumber("abc", 0).hasError);
    assert(wholeNumber("", 0).error.code == ParseErrorCode.emptyInput);
    assert(wholeNumber("   ", 0).error.code == ParseErrorCode.emptyInput);

    // 21 digits overflows `ulong`, and says so rather than wrapping.
    auto huge = wholeNumber("999999999999999999999", 0);
    assert(huge.hasError);
    assert(huge.error.code == ParseErrorCode.numericOverflow);
}

@("coverage.record.wholeNumberOffsets")
@betterC
unittest
{
    // The reported offset points at the offending character, not the field.
    auto bad = wholeNumber("  12x", 100);
    assert(bad.hasError);
    assert(bad.error.offset == 104);
}
