/// The tolerant RFC 4180 parser (`DSM1`–`DSM3` in
/// `docs/specs/hue/dsv-preview.md`): quoted fields, embedded delimiters and
/// **newlines**, doubled-quote escapes — plus the tolerated real-world
/// deviations: quotes in an unquoted field are literal, a quote after a
/// quoted field's content **re-enters** quoted mode (the Excel behavior),
/// and a final record without a terminator is a record. Ragged rows are
/// counted, never rejected; an unterminated quote runs to end of input and
/// sets a diagnostic.
///
/// Every cell records its **raw byte span** (quotes included) — the
/// identity channel (`DSM2`); records remember their own terminator and a
/// leading UTF-8 BOM is stripped but accounted (`DSD6`), so
/// whole-document serialization can reproduce the input byte-for-byte
/// (`DSC4`). Single pass, `@safe pure nothrow @nogc`, no copies of the
/// source (`DSN1`).
module sparkles.dsv.parse;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.errors : ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.dsv.model : CellFlags, Dialect, DsvCell, DsvDoc, DsvRecord,
    Span, Terminator;

/// Parses `source` under `dialect` into a [DsvDoc] borrowing `source`.
/// Fails only on an unusable dialect (delimiter/quote equal, or either a
/// CR/LF byte); the parse itself is total — malformed content degrades into
/// the tolerances above.
ParseExpected!DsvDoc parseDsv(const(char)[] source, in Dialect dialect)
    @safe pure nothrow @nogc
{
    const d = dialect.delimiter, q = dialect.quote;
    if (d == q || d == '\r' || d == '\n' || q == '\r' || q == '\n')
        return parseErr!DsvDoc(ParseErrorCode.unexpectedCharacter, 0,
            "delimiter and quote must be distinct, non-newline bytes");

    DsvDoc doc;
    doc.source = source;
    doc.dialect = dialect;

    size_t i = 0;
    if (source.length >= 3 && source[0 .. 3] == "\xEF\xBB\xBF")
    {
        doc.bomLength = 3;
        i = 3;
    }

    while (i < source.length)
    {
        const recStart = i;
        const cellsStart = cast(uint) doc.cells.length;
        uint cellCount = 0;
        Terminator term = Terminator.none;
        size_t recEnd = i;
        bool recordDone = false;

        while (!recordDone)
        {
            // One field, starting at `i`.
            const fieldStart = i;
            bool startedQuoted = false;
            bool inQuotes = false;
            if (i < source.length && source[i] == q)
            {
                startedQuoted = true;
                inQuotes = true;
                i++;
            }
            while (i < source.length)
            {
                const c = source[i];
                if (inQuotes)
                {
                    if (c == q)
                    {
                        if (i + 1 < source.length && source[i + 1] == q)
                            i += 2; // escaped quote
                        else
                        {
                            inQuotes = false;
                            i++;
                        }
                    }
                    else
                        i++; // delimiters and newlines are content here
                }
                else
                {
                    if (c == d || c == '\n')
                        break;
                    if (c == '\r')
                    {
                        if (i + 1 < source.length && source[i + 1] == '\n')
                            break;
                        i++; // a lone CR is a literal byte (`DSD6`)
                        continue;
                    }
                    if (c == q && startedQuoted)
                    {
                        // Re-enter quoted mode after field content (`DSM1`).
                        inQuotes = true;
                        i++;
                        continue;
                    }
                    i++; // an unquoted field's quotes are literal
                }
            }
            if (inQuotes)
                doc.unterminatedQuote = true;

            const fieldEnd = i;
            doc.cells ~= DsvCell(Span(fieldStart, fieldEnd - fieldStart),
                startedQuoted ? CellFlags.quoted : CellFlags.none);
            cellCount++;

            if (i >= source.length)
            {
                term = Terminator.none;
                recEnd = fieldEnd;
                recordDone = true;
            }
            else if (source[i] == d)
            {
                i++; // next field
            }
            else if (source[i] == '\n')
            {
                term = Terminator.lf;
                recEnd = fieldEnd;
                i++;
                recordDone = true;
            }
            else // "\r\n"
            {
                term = Terminator.crlf;
                recEnd = fieldEnd;
                i += 2;
                recordDone = true;
            }
        }

        doc.records ~= DsvRecord(cellsStart, cellCount, term,
            Span(recStart, recEnd - recStart));
    }

    finishCounts(doc);
    return parseOk(doc);
}

/// Column-count bookkeeping (`DSM3`): the grid is as wide as the widest
/// record; raggedness is measured against the **modal** (most frequent)
/// cell count, ties preferring the larger count (a grid grows).
private void finishCounts(ref DsvDoc doc) @safe pure nothrow @nogc
{
    uint maxCols = 0;
    foreach (r; 0 .. doc.records.length)
        if (doc.records[r].cellCount > maxCols)
            maxCols = doc.records[r].cellCount;
    doc.columnCount = maxCols;
    if (doc.records.length == 0)
        return;

    SmallBuffer!(uint, 64) hist;
    foreach (_; 0 .. maxCols + 1)
        hist ~= 0u;
    foreach (r; 0 .. doc.records.length)
        hist[doc.records[r].cellCount]++;

    uint modal = 0, best = 0;
    foreach (count; 0 .. maxCols + 1)
        if (hist[count] >= best && hist[count] > 0)
        {
            best = hist[count];
            modal = cast(uint) count;
        }
    doc.modalColumnCount = modal;

    uint ragged = 0;
    foreach (r; 0 .. doc.records.length)
        if (doc.records[r].cellCount != modal)
            ragged++;
    doc.raggedCount = ragged;
}

version (unittest)
{
    import sparkles.dsv.model : decodeCell;

    /// Test helper: the decoded text of cell `(row, col)`. (A template so
    /// dip1000 attributes infer; `doc` is a plain ref — the result borrows
    /// from it or from `buf`.)
    private const(char)[] cellAt()(ref SmallBuffer!(char, 256) buf,
        ref const DsvDoc doc, size_t row, size_t col)
    {
        const rec = doc.records[row];
        return decodeCell(doc, doc.cells[rec.cellsStart + col], buf);
    }
}

@("parse.basic.commaGrid")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("a,b,c\n1,2,3\n", Dialect(',')).value;
    assert(doc.records.length == 2);
    assert(doc.columnCount == 3);
    assert(doc.modalColumnCount == 3);
    assert(doc.raggedCount == 0);
    assert(!doc.unterminatedQuote);
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 0, 0) == "a");
    assert(cellAt(buf, doc, 1, 2) == "3");
    assert(doc.records[0].terminator == Terminator.lf);
}

@("parse.dialect.invalid")
@safe pure nothrow @nogc
unittest
{
    assert(parseDsv("a", Dialect('"', '"')).hasError);
    assert(parseDsv("a", Dialect('\n')).hasError);
    assert(parseDsv("a", Dialect(',', '\r')).hasError);
}

@("parse.quoting.embeddedDelimiterAndNewline")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("\"a,b\",\"l1\nl2\"\nx,y\n", Dialect(',')).value;
    assert(doc.records.length == 2);
    assert(doc.records[0].cellCount == 2);
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 0, 0) == "a,b");
    assert(cellAt(buf, doc, 0, 1) == "l1\nl2");
    // The identity channel spans the raw bytes, quotes included (DSM2).
    assert(doc.cellRaw(doc.cells[0]) == "\"a,b\"");
}

@("parse.quoting.doubledQuoteEscape")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("\"he said \"\"hi\"\"\",b\n", Dialect(',')).value;
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 0, 0) == "he said \"hi\"");
    assert(cellAt(buf, doc, 0, 1) == "b");
}

@("parse.deviations.unquotedQuoteIsLiteral")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("a\"b,c\n", Dialect(',')).value;
    assert(doc.records[0].cellCount == 2);
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 0, 0) == "a\"b");
    assert(!doc.cells[0].needsDecode);
}

@("parse.deviations.excelReentry")
@safe pure nothrow @nogc
unittest
{
    // `"a"b"c,d"` — quoted "a", literal b, re-entered quoted "c,d" whose
    // comma is content again (the Excel behavior, DSM1).
    const doc = parseDsv("\"a\"b\"c,d\",e\n", Dialect(',')).value;
    assert(doc.records[0].cellCount == 2);
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 0, 0) == "abc,d");
    assert(cellAt(buf, doc, 0, 1) == "e");
}

@("parse.deviations.unterminatedQuoteRunsToEnd")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("a,\"open\nstill open", Dialect(',')).value;
    assert(doc.unterminatedQuote);
    assert(doc.records.length == 1);
    assert(doc.records[0].cellCount == 2);
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 0, 1) == "open\nstill open");
    assert(doc.records[0].terminator == Terminator.none);
}

@("parse.terminators.crlfLfMixedAndFinal")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("a,b\r\nc,d\ne,f", Dialect(',')).value;
    assert(doc.records.length == 3);
    assert(doc.records[0].terminator == Terminator.crlf);
    assert(doc.records[1].terminator == Terminator.lf);
    assert(doc.records[2].terminator == Terminator.none);
    // Record raw spans exclude the terminator.
    assert(doc.source[doc.records[0].raw.start .. doc.records[0].raw.end] == "a,b");
}

@("parse.terminators.loneCrIsLiteral")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("a\rb,c\n", Dialect(',')).value;
    assert(doc.records.length == 1);
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 0, 0) == "a\rb");
}

@("parse.bom.strippedAndAccounted")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("\xEF\xBB\xBFa,b\n", Dialect(',')).value;
    assert(doc.bomLength == 3);
    assert(doc.records.length == 1);
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 0, 0) == "a");
    assert(doc.cells[0].raw.start == 3);
}

@("parse.ragged.countsAgainstModal")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("a,b,c\n1,2\n3,4,5\n6,7,8,9\n0,1,2\n", Dialect(',')).value;
    assert(doc.columnCount == 4); // the widest record grows the grid
    assert(doc.modalColumnCount == 3);
    assert(doc.raggedCount == 2); // the 2-cell and the 4-cell record
}

@("parse.edges.emptyAndHeaderOnly")
@safe pure nothrow @nogc
unittest
{
    const empty = parseDsv("", Dialect(',')).value;
    assert(empty.records.length == 0);
    assert(empty.columnCount == 0);

    const headerOnly = parseDsv("name,age\n", Dialect(',')).value;
    assert(headerOnly.records.length == 1);
    assert(headerOnly.columnCount == 2);
}

@("parse.edges.emptyLineIsOneEmptyCell")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("a,b\n\nc,d\n", Dialect(',')).value;
    assert(doc.records.length == 3);
    assert(doc.records[1].cellCount == 1);
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 1, 0) == "");
}

@("parse.edges.trailingDelimiterMakesEmptyCell")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("a,b,\n", Dialect(',')).value;
    assert(doc.records[0].cellCount == 3);
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 0, 2) == "");
}

@("parse.dialects.tabSemicolonPipe")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(char, 256) buf;
    const tsv = parseDsv("a\tb\nc\td\n", Dialect('\t')).value;
    assert(tsv.columnCount == 2);
    assert(cellAt(buf, tsv, 1, 1) == "d");

    const ssv = parseDsv("x;1,5\ny;2,7\n", Dialect(';')).value;
    assert(ssv.columnCount == 2);
    assert(cellAt(buf, ssv, 0, 1) == "1,5");

    const psv = parseDsv("p|q\n", Dialect('|')).value;
    assert(psv.columnCount == 2);
}

@("parse.quoting.singleQuoteDialect")
@safe pure nothrow @nogc
unittest
{
    const doc = parseDsv("'a,b',c\n", Dialect(',', '\'')).value;
    assert(doc.records[0].cellCount == 2);
    SmallBuffer!(char, 256) buf;
    assert(cellAt(buf, doc, 0, 0) == "a,b");
}

@("parse.inference.typedColumnsAndThreshold")
@safe unittest
{
    import std.array : appender;
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.dsv.model : ColumnType, inferColumnTypes;

    // Columns: text · integer-with-1/20-outlier (95%, passes) ·
    // integer-with-2/20-outliers (90%, fails to text) · float-with-ints ·
    // bool · ISO date.
    auto a = appender!string;
    foreach (i; 0 .. 20)
    {
        const outlier1 = i == 0 ? "x" : "7";
        const outlier2 = i <= 1 ? "x" : "7";
        const flt = i % 2 == 0 ? "1.5" : "2";
        const b = i % 2 == 0 ? "true" : "FALSE";
        a ~= "name,";
        a ~= outlier1;
        a ~= ",";
        a ~= outlier2;
        a ~= ",";
        a ~= flt;
        a ~= ",";
        a ~= b;
        a ~= ",2026-08-18\n";
    }
    const doc = parseDsv(a[], Dialect(',')).value;
    SmallBuffer!(ColumnType, 16) types;
    inferColumnTypes(doc, 100, types);
    assert(types[0] == ColumnType.text);
    assert(types[1] == ColumnType.integer); // 19/20 = 95% — passes
    assert(types[2] == ColumnType.text); // 18/20 = 90% — fails
    assert(types[3] == ColumnType.floating); // integers satisfy floating
    assert(types[4] == ColumnType.boolean);
    assert(types[5] == ColumnType.date);
}

@("parse.hugeCell.quotedMultiline")
@safe unittest
{
    // A quoted cell far larger than any SBO capacity, with embedded
    // newlines and escapes throughout (the D0 gate's "huge cells" fixture).
    import std.array : appender, replicate;

    auto a = appender!string;
    a ~= "id,blob\n1,\"";
    const chunk = "line with \"\"quotes\"\" and,commas\n".replicate(500);
    a ~= chunk;
    a ~= "\"\n2,tail\n";
    const doc = parseDsv(a[], Dialect(',')).value;
    assert(doc.records.length == 3);
    assert(doc.records[1].cellCount == 2);
    SmallBuffer!(char, 256) buf;
    const decoded = decodeCell(doc, doc.cells[doc.records[1].cellsStart + 1], buf);
    assert(decoded.length == chunk.length - 500 * 2); // each "" collapses
    assert(cellAt(buf, doc, 2, 1) == "tail");
}
