/**
 * Byte-offset ↔ line/column conversion over an immutable text snapshot.
 *
 * `LineIndex` records the byte offset of every line start once, then answers
 * both directions in `O(log lines)` / `O(1)`: `lineColAt` (byte offset →
 * 0-based line + byte column) and `offsetAt` (0-based line + byte column →
 * byte offset). Columns are **UTF-8 code units (bytes)** from the line start —
 * not display cells, not code points — because every consumer in this repo
 * (the twoslash node model, `sparkles:syntax` events, tree-sitter spans)
 * indexes source text by byte.
 *
 * The `*Dmd` accessors adapt DMD's diagnostic coordinates — **1-based** line
 * and **1-based UTF-8-code-unit** column, i.e. the same units shifted by one —
 * so the conversion at the `sparkles:dmd-lsp` seam is explicit and in one
 * place (see `docs/specs/dmd-lsp/`, `NTN3`).
 *
 * Line terminators: `\n` ends a line (a `\r\n` pair's `\r` is part of the
 * preceding line's bytes, matching byte-faithful slicing). The text after the
 * last `\n` is a final (possibly empty) line, so every byte offset in
 * `[0, text.length]` maps to a valid position — `text.length` is the
 * one-past-the-end column of the last line.
 */
module sparkles.base.text.lineindex;

import sparkles.base.text.span : TextSpan;

/// A resolved position: 0-based line, 0-based byte column.
struct LineCol
{
    size_t line;
    size_t column;
}

/// Precomputed line-start table over one text snapshot.
struct LineIndex
{
    private size_t[] _lineStarts;
    private size_t _length;

    /// Build the index; `text` is only scanned, not stored.
    this(scope const(char)[] text) @safe pure nothrow
    {
        _length = text.length;
        _lineStarts = [0];
        foreach (i, c; text)
            if (c == '\n')
                _lineStarts ~= i + 1;
    }

    /// Number of lines (≥ 1 for the empty text: one empty line).
    size_t lineCount() const @safe pure nothrow @nogc => _lineStarts.length;

    /// Byte offset of the start of `line` (0-based).
    size_t lineStart(size_t line) const @safe pure nothrow @nogc
    in (line < _lineStarts.length, "line out of range")
        => _lineStarts[line];

    /// Resolve a byte offset (≤ text length) to its 0-based line/column.
    LineCol lineColAt(size_t offset) const @safe pure nothrow @nogc
    in (offset <= _length, "offset past end of text")
    {
        // Binary search: last line start ≤ offset.
        size_t lo = 0, hi = _lineStarts.length;
        while (hi - lo > 1)
        {
            const mid = lo + (hi - lo) / 2;
            if (_lineStarts[mid] <= offset)
                lo = mid;
            else
                hi = mid;
        }
        return LineCol(lo, offset - _lineStarts[lo]);
    }

    /// Byte offset of 0-based `line`/`column` (column clamped to text end).
    size_t offsetAt(size_t line, size_t column) const @safe pure nothrow @nogc
    in (line < _lineStarts.length, "line out of range")
    {
        const off = _lineStarts[line] + column;
        return off < _length ? off : _length;
    }

    /// ditto
    size_t offsetAt(in LineCol pos) const @safe pure nothrow @nogc
        => offsetAt(pos.line, pos.column);

    /// Byte offset for DMD coordinates: 1-based line, 1-based UTF-8 column.
    size_t offsetOfDmd(size_t line, size_t column) const @safe pure nothrow @nogc
    in (line >= 1, "DMD lines are 1-based")
    in (column >= 1, "DMD columns are 1-based")
        => offsetAt(line - 1, column - 1);

    /// 0-based line/column for DMD coordinates (see `offsetOfDmd`).
    LineCol dmdToLineCol(size_t line, size_t column) const @safe pure nothrow @nogc
    in (line >= 1, "DMD lines are 1-based")
    in (column >= 1, "DMD columns are 1-based")
        => LineCol(line - 1, column - 1);

    /// Resolve a `TextSpan` to its 0-based `(startLineCol, endLineCol)` range.
    LineColRange lineColRange(in TextSpan span) const @safe pure nothrow @nogc
    in (span.isValid, "cannot resolve an invalid TextSpan")
    in (span.endOffset <= _length, "TextSpan endOffset past end of text")
        => LineColRange(lineColAt(span.startOffset), lineColAt(span.endOffset));
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
