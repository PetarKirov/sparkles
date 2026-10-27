/**
 * Byte-offset ↔ line/column conversion over an immutable text snapshot.
 *
 * `LineIndex` records the byte offset of every line start once, then answers
 * both directions in `O(log lines)` / `O(1)`: `lineColAt` (byte offset →
 * 0-based line + column) and `offsetAt` (0-based line + byte column → byte
 * offset). Columns default to **UTF-8 code units (bytes)** from the line
 * start — not display cells, not code points — because most consumers in this
 * repo (the twoslash node model, `sparkles:syntax` events, tree-sitter spans)
 * index source text by byte. The `lineColAt(offset, text)` overload counts
 * UTF-8 sequences instead, one column per invalid byte, for a consumer that
 * reports scalar columns (the SDL backend); the index never stores the text.
 *
 * The `*Dmd` accessors adapt DMD's diagnostic coordinates — **1-based** line
 * and **1-based UTF-8-code-unit** column, i.e. the same units shifted by one —
 * so the conversion at the `sparkles:dmd-lsp` seam is explicit and in one
 * place (see `docs/specs/dmd-lsp/`, `NTN3`).
 *
 * Line terminators follow a $(LREF NewlinePolicy). The default, `lf`, ends a
 * line at `\n` only (a `\r\n` pair's `\r` is part of the preceding line's
 * bytes, matching byte-faithful slicing); `logical` also ends one at `\r`,
 * `\r\n` (one break), U+2028 and U+2029. The text after the last break is a
 * final (possibly empty) line, so every byte offset in `[0, text.length]`
 * maps to a valid position — `text.length` is the one-past-the-end column of
 * the last line. Line 0 may start after a prefix such as a byte-order mark;
 * offsets inside that prefix resolve to line 0, column 0.
 *
 * The table lives in a copy-on-write `SharedBuffer`, so building an index is
 * `@nogc` and copying one shares the table.
 */
module sparkles.base.text.lineindex;

import sparkles.base.buffer : SharedBuffer;
import sparkles.base.text.span : TextSpan;
import sparkles.base.text.utf8 : utf8SequenceLength;

/// A resolved position: 0-based line, 0-based column.
struct LineCol
{
    size_t line;
    size_t column;
}

/// Which byte sequences end a line.
enum NewlinePolicy : ubyte
{
    /// `\n` only — the default.
    lf,
    /// `\n`, `\r`, `\r\n` (one break), U+2028 and U+2029 — SDL's logical set.
    logical,
}

/// Precomputed line-start table over one text snapshot.
struct LineIndex
{
    private SharedBuffer!size_t _lineStarts;
    private size_t _length;

    /**
    Build the index by scanning `text`, which is not stored.

    Params:
        text = the text to index
        policy = which sequences end a line
        firstLineStart = where line 0 starts, e.g. after a byte-order mark
    */
    this(scope const(char)[] text, NewlinePolicy policy = NewlinePolicy.lf,
        size_t firstLineStart = 0) @safe pure nothrow @nogc
    in (firstLineStart <= text.length, "first line starts past end of text")
    {
        _length = text.length;
        _lineStarts.put(firstLineStart);
        const n = text.length;
        if (policy == NewlinePolicy.lf)
        {
            foreach (i; firstLineStart .. n)
                if (text[i] == '\n')
                    _lineStarts.put(i + 1);
            return;
        }
        size_t i = firstLineStart;
        while (i < n)
        {
            const c = text[i];
            if (c == '\n')
                i += 1;
            else if (c == '\r')
                i += i + 1 < n && text[i + 1] == '\n' ? 2 : 1;
            else if (c == '\xE2' && i + 2 < n && text[i + 1] == '\x80'
                && (text[i + 2] == '\xA8' || text[i + 2] == '\xA9'))
                i += 3;
            else
            {
                i++;
                continue;
            }
            _lineStarts.put(i);
        }
    }

    /**
    Build the index from line starts a caller already found, e.g. a lexer
    recording them in its single pass.

    Params:
        laterLineStarts = the start of every line after line 0, strictly
            increasing — the offset just past each line break
        textLength = the indexed text's length in bytes
        firstLineStart = where line 0 starts, e.g. after a byte-order mark
    */
    this(scope const(size_t)[] laterLineStarts, size_t textLength,
        size_t firstLineStart = 0) @safe pure nothrow @nogc
    in (firstLineStart <= textLength, "first line starts past end of text")
    {
        _length = textLength;
        _lineStarts.reserve(laterLineStarts.length + 1);
        _lineStarts.put(firstLineStart);
        foreach (start; laterLineStarts)
        {
            assert(start > _lineStarts[$ - 1], "line starts must strictly increase");
            assert(start <= textLength, "line start past end of text");
            _lineStarts.put(start);
        }
    }

    /// Number of lines (≥ 1 for the empty text: one empty line).
    size_t lineCount() const scope @safe pure nothrow @nogc => _lineStarts.length;

    /// Byte offset of the start of `line` (0-based).
    size_t lineStart(size_t line) const scope @safe pure nothrow @nogc
    in (line < _lineStarts.length, "line out of range")
        => _lineStarts[line];

    /// Resolve a byte offset (≤ text length) to its 0-based line and byte
    /// column.
    LineCol lineColAt(size_t offset) const scope @safe pure nothrow @nogc
    in (offset <= _length, "offset past end of text")
    {
        const line = lineOf(offset);
        const start = _lineStarts[line];
        return LineCol(line, offset > start ? offset - start : 0);
    }

    /**
    Resolve a byte offset to its 0-based line and a column counted in UTF-8
    sequences: one per well-formed sequence, one per invalid byte.

    Params:
        offset = a byte offset ≤ the text length
        text = the text this index was built over
    */
    LineCol lineColAt(size_t offset, scope const(char)[] text) const scope @safe pure nothrow @nogc
    in (offset <= _length, "offset past end of text")
    in (text.length == _length, "text is not the indexed text")
    {
        const line = lineOf(offset);
        size_t at = _lineStarts[line];
        size_t column;
        while (at < offset)
        {
            const width = text[at] < 0x80 ? 1 : utf8SequenceLength(text, at);
            at += width ? width : 1;
            column++;
        }
        return LineCol(line, column);
    }

    /// Byte offset of 0-based `line`/`column` (column clamped to text end).
    size_t offsetAt(size_t line, size_t column) const scope @safe pure nothrow @nogc
    in (line < _lineStarts.length, "line out of range")
    {
        const off = _lineStarts[line] + column;
        return off < _length ? off : _length;
    }

    /// ditto
    size_t offsetAt(in LineCol pos) const scope @safe pure nothrow @nogc
        => offsetAt(pos.line, pos.column);

    /// Byte offset for DMD coordinates: 1-based line, 1-based UTF-8 column.
    size_t offsetOfDmd(size_t line, size_t column) const scope @safe pure nothrow @nogc
    in (line >= 1, "DMD lines are 1-based")
    in (column >= 1, "DMD columns are 1-based")
        => offsetAt(line - 1, column - 1);

    /// 0-based line/column for DMD coordinates (see `offsetOfDmd`).
    LineCol dmdToLineCol(size_t line, size_t column) const scope @safe pure nothrow @nogc
    in (line >= 1, "DMD lines are 1-based")
    in (column >= 1, "DMD columns are 1-based")
        => LineCol(line - 1, column - 1);

    /// Resolve a `TextSpan` to its 0-based `(startLineCol, endLineCol)` range.
    LineColRange lineColRange(in TextSpan span) const scope @safe pure nothrow @nogc
    in (span.isValid, "cannot resolve an invalid TextSpan")
    in (span.endOffset <= _length, "TextSpan endOffset past end of text")
        => LineColRange(lineColAt(span.startOffset), lineColAt(span.endOffset));

    // The last line whose start is ≤ `offset` (line 0 for a prefix offset).
    private size_t lineOf(size_t offset) const scope @safe pure nothrow @nogc
    {
        size_t lo = 0, hi = _lineStarts.length;
        while (hi - lo > 1)
        {
            const mid = lo + (hi - lo) / 2;
            if (_lineStarts[mid] <= offset)
                lo = mid;
            else
                hi = mid;
        }
        return lo;
    }
}

/// A resolved text range: 0-based start and end line/column positions.
struct LineColRange
{
    LineCol start;
    LineCol end;
}

@("lineindex.LineIndex.empty")
@safe pure nothrow
unittest
{
    const idx = LineIndex("");
    assert(idx.lineCount == 1);
    assert(idx.lineColAt(0) == LineCol(0, 0));
    assert(idx.offsetAt(0, 0) == 0);
}

@("lineindex.LineIndex.basic")
@safe pure nothrow
unittest
{
    //                     0123 456 789
    const idx = LineIndex("ab\nc\nde\n");
    assert(idx.lineCount == 4); // "ab", "c", "de", ""
    assert(idx.lineStart(0) == 0);
    assert(idx.lineStart(1) == 3);
    assert(idx.lineStart(2) == 5);
    assert(idx.lineStart(3) == 8);

    assert(idx.lineColAt(0) == LineCol(0, 0));
    assert(idx.lineColAt(2) == LineCol(0, 2)); // the '\n' belongs to line 0
    assert(idx.lineColAt(3) == LineCol(1, 0));
    assert(idx.lineColAt(6) == LineCol(2, 1));
    assert(idx.lineColAt(8) == LineCol(3, 0)); // one-past-the-end position

    assert(idx.offsetAt(2, 1) == 6);
    assert(idx.offsetAt(idx.lineColAt(6)) == 6);
}

@("lineindex.LineIndex.crlf")
@safe pure nothrow
unittest
{
    //                     012 3 456
    const idx = LineIndex("a\r\nb\r\n");
    assert(idx.lineCount == 3);
    assert(idx.lineColAt(1) == LineCol(0, 1)); // '\r' is line 0's byte
    assert(idx.lineColAt(3) == LineCol(1, 0));
}

@("lineindex.LineIndex.nonAscii")
@safe pure nothrow
unittest
{
    // "α β\nγ" — α and γ are 2 UTF-8 bytes each.
    const text = "α β\nγ";
    const idx = LineIndex(text);
    assert(idx.lineCount == 2);
    assert(idx.lineStart(1) == 6); // "α β" = 2 + 1 + 2 bytes, + '\n'
    assert(idx.lineColAt(3) == LineCol(0, 3)); // mid-line byte column
    assert(idx.lineColAt(6) == LineCol(1, 0));
    assert(idx.offsetAt(1, 2) == 8); // one past γ's 2 bytes == text end
}

@("lineindex.LineIndex.dmdCoordinates")
@safe pure nothrow
unittest
{
    const idx = LineIndex("int x;\nint y;\n");
    // DMD reports 1-based line/column: line 2 column 5 is 'y'.
    assert(idx.offsetOfDmd(2, 5) == 11);
    assert(idx.dmdToLineCol(2, 5) == LineCol(1, 4));
    assert(idx.lineColAt(idx.offsetOfDmd(1, 1)) == LineCol(0, 0));
}

@("lineindex.LineIndex.roundTrip")
@safe pure nothrow
unittest
{
    const text = "module m;\n\nvoid f()\n{\n    return;\n}\n";
    const idx = LineIndex(text);
    foreach (offset; 0 .. text.length + 1)
        assert(idx.offsetAt(idx.lineColAt(offset)) == offset);
}

@("lineindex.LineIndex.lineColRange")
@safe pure nothrow
unittest
{
    //                     0123 456 789
    const idx = LineIndex("ab\nc\nde\n");
    const span = TextSpan(1, 7); // from 'b' (line 0, col 1) to 'e' (line 2, col 2)
    const range = idx.lineColRange(span);
    assert(range.start == LineCol(0, 1));
    assert(range.end == LineCol(2, 2));
}

///
@("lineindex.LineIndex.logicalNewlines")
@safe pure nothrow @nogc
unittest
{
    // Every SDL line break: `\r`, `\n`, `\r\n`, U+2028, U+2029.
    enum text = "a\rb\nc\r\nd\u2028e\u2029f";
    const idx = LineIndex(text, NewlinePolicy.logical);
    static immutable size_t[6] starts = [0, 2, 4, 7, 11, 15];
    assert(idx.lineCount == starts.length);
    foreach (line, start; starts)
    {
        assert(idx.lineStart(line) == start);
        assert(idx.lineColAt(start) == LineCol(line, 0));
    }
    // Inside a `\r\n` pair is still the earlier line.
    assert(idx.lineColAt(6) == LineCol(2, 2));
    // The default policy sees two `\n`s only.
    assert(LineIndex(text).lineCount == 3);
}

@("lineindex.LineIndex.logicalNewlineEdges")
@safe pure nothrow @nogc
unittest
{
    // A trailing `\r`, a `\r\r\n` run, and a truncated U+2028 lead.
    assert(LineIndex("a\r", NewlinePolicy.logical).lineCount == 2);
    const run = LineIndex("\r\r\n", NewlinePolicy.logical);
    assert(run.lineCount == 3 && run.lineStart(1) == 1 && run.lineStart(2) == 3);
    assert(LineIndex("x\xE2\x80", NewlinePolicy.logical).lineCount == 1);
    // U+2027 is not a line break.
    assert(LineIndex("x\u2027y", NewlinePolicy.logical).lineCount == 1);
}

///
@("lineindex.LineIndex.byteOrderMark")
@safe pure nothrow @nogc
unittest
{
    // Line 0 starts after the byte-order mark; its bytes resolve to (0, 0).
    enum text = "\xEF\xBB\xBFname\nx";
    const idx = LineIndex(text, NewlinePolicy.logical, firstLineStart: 3);
    assert(idx.lineStart(0) == 3);
    assert(idx.lineColAt(3) == LineCol(0, 0));
    assert(idx.lineColAt(5) == LineCol(0, 2));
    assert(idx.lineColAt(1) == LineCol(0, 0));
    assert(idx.lineColAt(1, text) == LineCol(0, 0));
    assert(idx.lineColAt(8) == LineCol(1, 0));
    assert(idx.offsetAt(0, 0) == 3);
}

///
@("lineindex.LineIndex.scalarColumns")
@safe pure nothrow @nogc
unittest
{
    // "α β\nγx": byte columns count α's two bytes, scalar columns one.
    enum text = "α β\nγx";
    const idx = LineIndex(text);
    assert(idx.lineColAt(5) == LineCol(0, 5));
    assert(idx.lineColAt(5, text) == LineCol(0, 3));
    assert(idx.lineColAt(9, text) == LineCol(1, 2));
    assert(idx.lineColAt(0, text) == LineCol(0, 0));
}

@("lineindex.LineIndex.invalidUtf8Columns")
@safe pure nothrow @nogc
unittest
{
    // One column per invalid byte: a stray continuation, a truncated
    // 3-byte lead, an overlong lead, then a valid "é" and "z".
    enum text = "\x80\xE2\x82\xC0\xAFéz";
    const idx = LineIndex(text);
    assert(idx.lineColAt(1, text) == LineCol(0, 1));
    assert(idx.lineColAt(2, text) == LineCol(0, 2)); // E2 alone
    assert(idx.lineColAt(3, text) == LineCol(0, 3)); // 82 alone
    assert(idx.lineColAt(5, text) == LineCol(0, 5)); // C0 AF: two
    assert(idx.lineColAt(7, text) == LineCol(0, 6)); // é is one
    assert(idx.lineColAt(8, text) == LineCol(0, 7));
}

///
@("lineindex.LineIndex.knownStarts")
@safe pure nothrow @nogc
unittest
{
    // A lexer that found the starts itself hands them over with the length.
    enum text = "\xEF\xBB\xBFa\rb\r\nc";
    static immutable size_t[2] later = [5, 8];
    const known = LineIndex(later[], text.length, firstLineStart: 3);
    const scanned = LineIndex(text, NewlinePolicy.logical, firstLineStart: 3);
    assert(known.lineCount == scanned.lineCount);
    foreach (line; 0 .. known.lineCount)
        assert(known.lineStart(line) == scanned.lineStart(line));
    foreach (offset; 0 .. text.length + 1)
        assert(known.lineColAt(offset, text) == scanned.lineColAt(offset, text));
}

@("lineindex.LineIndex.copiesShareAndReassign")
@safe pure nothrow @nogc
unittest
{
    // A stored index is copied and reassigned (the twoslash analyzer does).
    LineIndex idx;
    assert(idx.lineCount == 0);
    idx = LineIndex("a\nb\nc\nd\ne\n");
    const copy = idx;
    idx = LineIndex("x");
    assert(copy.lineCount == 6 && copy.lineStart(5) == 10);
    assert(idx.lineCount == 1);
}
