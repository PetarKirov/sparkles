/// The DSV document model (`DSM*` in `docs/specs/hue/dsv-preview.md`):
/// records → cells, each cell carrying its **raw byte span** into the
/// borrowed source — the identity channel (`DSM2`) that later selection /
/// copy features resolve against — plus the resolved [Dialect], ragged-row
/// accounting (`DSM3`), and sampled typed columns (`DSM4`).
///
/// The model is **`@nogc` by construction** (`DSM5`, the `sparkles:diff`
/// discipline): a flat arena of plain-old-data structs of spans and indices,
/// owned by `SmallBuffer`; the source text is **borrowed** (it must outlive
/// the document) and is never copied — resident overhead is proportional to
/// record count, not content size (`DSN1`). Quoted cells decode lazily
/// ([decodeCell]); a simple cell's text **is** its raw span ([cellRaw]).
module sparkles.dsv.model;

import sparkles.base.smallbuffer : SmallBuffer;

/// A byte span into the borrowed source.
struct Span
{
    size_t start;
    size_t length;

    size_t end() const @safe pure nothrow @nogc => start + length;
}

/// How the first record is interpreted; `auto_` defers to the sniffer's
/// heuristic (`DSD3`).
enum HeaderMode : ubyte
{
    auto_,
    yes,
    no,
}

/// The resolved delimiter/quote pair a document is parsed with (`DSD*`).
/// Produced by the sniffer or forced by flags; recorded on the document so
/// serializers can re-emit the source dialect later (`DSC2`).
struct Dialect
{
    char delimiter = ',';
    char quote = '"';
}

/// How one record was terminated in the source (`DSD6`) — remembered
/// per-record so whole-document reproduction stays byte-exact (`DSC4`).
enum Terminator : ubyte
{
    /// End of input, no trailing newline.
    none,
    lf,
    crlf,
}

/// Per-cell flags.
enum CellFlags : ubyte
{
    none = 0,
    /// The cell contains at least one quoted segment: its decoded text
    /// differs from its raw span, so it needs [decodeCell].
    quoted = 1 << 0,
}

/// One cell. Plain data: `raw` spans the borrowed source **including** any
/// quotes/escapes (the identity channel, `DSM2`); [cellRaw]/[decodeCell]
/// resolve the text.
struct DsvCell
{
    Span raw;
    ubyte flags;

    bool needsDecode() const @safe pure nothrow @nogc
        => (flags & CellFlags.quoted) != 0;
}

/// One record: its cell range in the document's `cells` arena, its raw span
/// (terminator excluded), and how it was terminated.
struct DsvRecord
{
    uint cellsStart;
    uint cellCount;
    Terminator terminator;
    Span raw;
}

/// The classification of one decoded cell value ([classifyValue]).
enum ValueKind : ubyte
{
    empty,
    integer,
    floating,
    /// ISO 8601: `YYYY-MM-DD`, optionally `T`/space `hh:mm[:ss[.frac]]`
    /// with an optional `Z`/`±hh:mm` offset.
    date,
    /// `true` / `false`, ASCII case-insensitive.
    boolean,
    text,
}

/// One column's inferred type (`DSM4`): the most specific type at least 95%
/// of the sampled non-empty cells satisfy, else `text`. Drives alignment and
/// typed comparison — never the rendering of the value itself.
enum ColumnType : ubyte
{
    text,
    integer,
    floating,
    date,
    boolean,
}

/// The parsed document: flat arenas over a borrowed source.
struct DsvDoc
{
    /// The backing text every span resolves against. Borrowed — must outlive
    /// the document. Includes any BOM (spans never cover it).
    const(char)[] source;

    Dialect dialect;

    SmallBuffer!DsvRecord records;
    SmallBuffer!DsvCell cells;

    /// The widest record's cell count — the grid's column count (`DSM3`:
    /// a long record grows the grid).
    uint columnCount;
    /// The most frequent cell count — raggedness is measured against it.
    uint modalColumnCount;
    /// Records whose cell count differs from `modalColumnCount` (`DSM3`).
    uint raggedCount;
    /// 3 when the source began with a UTF-8 BOM (stripped before the first
    /// record; reproduced by whole-document serialization, `DSD6`), else 0.
    uint bomLength;
    /// A quoted segment was still open at end of input (tolerated: the cell
    /// runs to the end, `DSM1`) — surfaced as a diagnostic.
    bool unterminatedQuote;
    /// Whether the first record is a header (from the sniffer's heuristic
    /// or forced, `DSD3`). Presentation state, not a parse fact.
    bool hasHeader;

@safe pure nothrow @nogc:

    /// The cells of record `r`.
    const(DsvCell)[] recordCells(in DsvRecord r) const return scope
        => cells[][r.cellsStart .. r.cellsStart + r.cellCount];

    /// A cell's raw text — exactly the source bytes, quotes included.
    const(char)[] cellRaw(in DsvCell c) const return scope
        => source[c.raw.start .. c.raw.end];

    /// The number of data records (the header, when present, excluded).
    size_t dataRecordCount() const
        => records.length == 0 ? 0 : records.length - (hasHeader ? 1 : 0);
}

/// Decodes a quoted cell into `buf` and returns the decoded slice; a simple
/// cell is returned borrowed without touching `buf`. Decoding mirrors the
/// parser's segment states (`DSM1`): quoted segments drop their quotes and
/// collapse doubled quotes, literal segments copy verbatim.
const(char)[] decodeCell(Buf)(in DsvDoc doc, in DsvCell cell, ref Buf buf)
{
    if (!cell.needsDecode)
        return doc.cellRaw(cell);

    const raw = doc.cellRaw(cell);
    const quote = doc.dialect.quote;
    buf.clear();
    size_t i = 0;
    bool inQuotes = raw.length > 0 && raw[0] == quote;
    if (inQuotes)
        i = 1;
    while (i < raw.length)
    {
        const c = raw[i];
        if (inQuotes)
        {
            if (c == quote)
            {
                if (i + 1 < raw.length && raw[i + 1] == quote)
                {
                    buf ~= quote;
                    i += 2;
                }
                else
                {
                    inQuotes = false;
                    i++;
                }
            }
            else
            {
                buf ~= c;
                i++;
            }
        }
        else if (c == quote)
        {
            // A quote after field content re-enters quoted mode (`DSM1`,
            // the Excel behavior the parser mirrors).
            inQuotes = true;
            i++;
        }
        else
        {
            buf ~= c;
            i++;
        }
    }
    return buf[];
}

@("model.DsvDoc.arenas")
@safe pure nothrow @nogc
unittest
{
    DsvDoc doc;
    doc.source = "a,b";
    doc.cells ~= DsvCell(Span(0, 1));
    doc.cells ~= DsvCell(Span(2, 1));
    doc.records ~= DsvRecord(0, 2, Terminator.none, Span(0, 3));
    assert(doc.recordCells(doc.records[][0]).length == 2);
    assert(doc.cellRaw(doc.cells[][1]) == "b");
    assert(doc.dataRecordCount == 1);
    doc.hasHeader = true;
    assert(doc.dataRecordCount == 0);
}

@("model.decodeCell.simpleBorrows")
@safe pure nothrow @nogc
unittest
{
    DsvDoc doc;
    doc.source = "plain";
    const cell = DsvCell(Span(0, 5));
    SmallBuffer!(char, 64) buf;
    const text = decodeCell(doc, cell, buf);
    assert(text == "plain");
    assert(buf.length == 0); // borrowed, not copied
}

@("model.decodeCell.quotedEscapes")
@safe pure nothrow @nogc
unittest
{
    DsvDoc doc;
    doc.source = `"he said ""hi"", left"`;
    const cell = DsvCell(Span(0, doc.source.length), CellFlags.quoted);
    SmallBuffer!(char, 64) buf;
    assert(decodeCell(doc, cell, buf) == `he said "hi", left`);
}

@("model.decodeCell.excelReentry")
@safe pure nothrow @nogc
unittest
{
    // `"a"b"c"` — quoted "a", literal b, re-entered quoted "c" (`DSM1`).
    DsvDoc doc;
    doc.source = `"a"b"c"`;
    const cell = DsvCell(Span(0, doc.source.length), CellFlags.quoted);
    SmallBuffer!(char, 64) buf;
    assert(decodeCell(doc, cell, buf) == "abc");
}

/// Classifies one decoded cell value (`DSM4`). Surrounding ASCII
/// space/tab is ignored for classification only — the value itself is
/// never trimmed anywhere else.
ValueKind classifyValue(scope const(char)[] s) @safe pure nothrow @nogc
{
    // Trim ASCII space/tab for classification.
    size_t a = 0, b = s.length;
    while (a < b && (s[a] == ' ' || s[a] == '\t'))
        a++;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t'))
        b--;
    const t = s[a .. b];

    if (t.length == 0)
        return ValueKind.empty;
    if (isBoolean(t))
        return ValueKind.boolean;
    if (isIsoDate(t))
        return ValueKind.date;
    const n = classifyNumber(t);
    if (n != ValueKind.text)
        return n;
    return ValueKind.text;
}

private bool isBoolean(scope const(char)[] t) @safe pure nothrow @nogc
{
    bool eqIgnoreCase(scope const(char)[] a, scope const(char)[] b)
    {
        if (a.length != b.length)
            return false;
        foreach (i; 0 .. a.length)
        {
            const ca = a[i] | 0x20, cb = b[i] | 0x20;
            if (ca != cb)
                return false;
        }
        return true;
    }

    return eqIgnoreCase(t, "true") || eqIgnoreCase(t, "false");
}

private bool isDigit(char c) @safe pure nothrow @nogc => c >= '0' && c <= '9';

/// `integer` for `[+-]?digits`, `floating` when a `.` fraction and/or
/// `[eE]` exponent participates, else `text`.
private ValueKind classifyNumber(scope const(char)[] t) @safe pure nothrow @nogc
{
    size_t i = 0;
    if (i < t.length && (t[i] == '+' || t[i] == '-'))
        i++;
    size_t intDigits = 0;
    while (i < t.length && isDigit(t[i]))
    {
        i++;
        intDigits++;
    }
    size_t fracDigits = 0;
    bool sawDot = false;
    if (i < t.length && t[i] == '.')
    {
        sawDot = true;
        i++;
        while (i < t.length && isDigit(t[i]))
        {
            i++;
            fracDigits++;
        }
    }
    if (intDigits + fracDigits == 0)
        return ValueKind.text;
    bool sawExp = false;
    if (i < t.length && (t[i] == 'e' || t[i] == 'E'))
    {
        sawExp = true;
        i++;
        if (i < t.length && (t[i] == '+' || t[i] == '-'))
            i++;
        size_t expDigits = 0;
        while (i < t.length && isDigit(t[i]))
        {
            i++;
            expDigits++;
        }
        if (expDigits == 0)
            return ValueKind.text;
    }
    if (i != t.length)
        return ValueKind.text;
    return (sawDot || sawExp) ? ValueKind.floating : ValueKind.integer;
}

private bool isIsoDate(scope const(char)[] t) @safe pure nothrow @nogc
{
    // Date part: YYYY-MM-DD (month 01–12, day 01–31).
    if (t.length < 10)
        return false;
    static immutable size_t[8] digitAt = [0, 1, 2, 3, 5, 6, 8, 9];
    foreach (i; digitAt)
        if (!isDigit(t[i]))
            return false;
    if (t[4] != '-' || t[7] != '-')
        return false;
    const month = (t[5] - '0') * 10 + (t[6] - '0');
    const day = (t[8] - '0') * 10 + (t[9] - '0');
    if (month < 1 || month > 12 || day < 1 || day > 31)
        return false;
    if (t.length == 10)
        return true;

    // Optional time part.
    size_t i = 10;
    if (t[i] != 'T' && t[i] != ' ')
        return false;
    i++;
    if (i + 5 > t.length || !isDigit(t[i]) || !isDigit(t[i + 1]) || t[i + 2] != ':'
        || !isDigit(t[i + 3]) || !isDigit(t[i + 4]))
        return false;
    i += 5;
    if (i + 3 <= t.length && t[i] == ':' && isDigit(t[i + 1]) && isDigit(t[i + 2]))
    {
        i += 3;
        if (i < t.length && t[i] == '.')
        {
            i++;
            size_t frac = 0;
            while (i < t.length && isDigit(t[i]))
            {
                i++;
                frac++;
            }
            if (frac == 0)
                return false;
        }
    }
    if (i == t.length)
        return true;
    if (t[i] == 'Z')
        return i + 1 == t.length;
    if (t[i] == '+' || t[i] == '-')
    {
        return i + 6 == t.length && isDigit(t[i + 1]) && isDigit(t[i + 2])
            && t[i + 3] == ':' && isDigit(t[i + 4]) && isDigit(t[i + 5]);
    }
    return false;
}

@("model.classifyValue.kinds")
@safe pure nothrow @nogc
unittest
{
    assert(classifyValue("") == ValueKind.empty);
    assert(classifyValue("  \t") == ValueKind.empty);
    assert(classifyValue("42") == ValueKind.integer);
    assert(classifyValue("-7") == ValueKind.integer);
    assert(classifyValue(" +13 ") == ValueKind.integer);
    assert(classifyValue("3.14") == ValueKind.floating);
    assert(classifyValue(".5") == ValueKind.floating);
    assert(classifyValue("5.") == ValueKind.floating);
    assert(classifyValue("1e9") == ValueKind.floating);
    assert(classifyValue("6.02E+23") == ValueKind.floating);
    assert(classifyValue("1e") == ValueKind.text);
    assert(classifyValue("TRUE") == ValueKind.boolean);
    assert(classifyValue("false") == ValueKind.boolean);
    assert(classifyValue("2026-08-18") == ValueKind.date);
    assert(classifyValue("2026-08-18T15:04") == ValueKind.date);
    assert(classifyValue("2026-08-18 15:04:05") == ValueKind.date);
    assert(classifyValue("2026-08-18T15:04:05.250Z") == ValueKind.date);
    assert(classifyValue("2026-08-18T15:04:05+02:00") == ValueKind.date);
    assert(classifyValue("2026-13-01") == ValueKind.text);
    assert(classifyValue("2026-08") == ValueKind.text);
    assert(classifyValue("hello") == ValueKind.text);
    assert(classifyValue("12abc") == ValueKind.text);
    assert(classifyValue("1,5") == ValueKind.text);
}

/// Whether one classified value satisfies a column type (an `integer` value
/// also satisfies a `floating` column).
package bool satisfies(ValueKind v, ColumnType t) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case ColumnType.boolean:
        return v == ValueKind.boolean;
    case ColumnType.date:
        return v == ValueKind.date;
    case ColumnType.integer:
        return v == ValueKind.integer;
    case ColumnType.floating:
        return v == ValueKind.integer || v == ValueKind.floating;
    case ColumnType.text:
        return true;
    }
}

/// Sampled per-column type inference (`DSM4`): over the first
/// `sampleRecords` **data** records (the header, when flagged, is skipped),
/// each column gets the most specific type at least 95% of its non-empty
/// cells satisfy — checked most-specific-first (`boolean`, `date`,
/// `integer`, `floating`) — else `text`. A column with no non-empty sampled
/// cell is `text`. Appends `doc.columnCount` entries to `types`.
void inferColumnTypes(Buf)(in DsvDoc doc, size_t sampleRecords, ref Buf types)
    => inferColumnTypesFrom(doc, doc.hasHeader ? 1 : 0, sampleRecords, types);

/// ditto, sampling from an explicit `firstRecord` — the header heuristic
/// (`DSD3`) types the body without mutating the document's `hasHeader`.
void inferColumnTypesFrom(Buf)(in DsvDoc doc, size_t firstRecord,
    size_t sampleRecords, ref Buf types)
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // kindCounts[col * kinds + kind]
    enum kinds = 6;
    SmallBuffer!(uint, 6 * 16) counts;
    foreach (_; 0 .. doc.columnCount * kinds)
        counts ~= 0u;

    SmallBuffer!(char, 256) decodeBuf;
    const first = firstRecord;
    const last = doc.records.length < first + sampleRecords
        ? doc.records.length : first + sampleRecords;
    foreach (r; first .. last)
    {
        const rec = doc.records[][r];
        foreach (ci, cell; doc.recordCells(rec))
        {
            const kind = classifyValue(decodeCell(doc, cell, decodeBuf));
            counts[ci * kinds + kind]++;
        }
    }

    static immutable ColumnType[4] bySpecificity =
        [ColumnType.boolean, ColumnType.date, ColumnType.integer, ColumnType.floating];

    foreach (col; 0 .. doc.columnCount)
    {
        // Kinds 1 (integer) through 5 (text) are the non-empty ones.
        uint nonEmpty = 0;
        foreach (kv; cast(ubyte) ValueKind.integer .. cast(ubyte)(ValueKind.text) + 1)
            nonEmpty += counts[col * kinds + kv];
        ColumnType inferred = ColumnType.text;
        if (nonEmpty > 0)
        {
            foreach (cand; bySpecificity)
            {
                uint sat = 0;
                foreach (kv; cast(ubyte) ValueKind.integer .. cast(ubyte)(ValueKind.text) + 1)
                    if (satisfies(cast(ValueKind) kv, cand))
                        sat += counts[col * kinds + kv];
                // sat / nonEmpty >= 95%
                if (sat * 100 >= nonEmpty * 95)
                {
                    inferred = cand;
                    break;
                }
            }
        }
        types ~= inferred;
    }
}

@("model.inferColumnTypes.handBuiltDoc")
@safe pure nothrow @nogc
unittest
{
    // "a,1\nb,2\nc,3" — a text column and an integer column.
    DsvDoc doc;
    doc.source = "a,1\nb,2\nc,3";
    foreach (r; 0 .. 3)
    {
        const base = r * 4;
        doc.cells ~= DsvCell(Span(base, 1));
        doc.cells ~= DsvCell(Span(base + 2, 1));
        doc.records ~= DsvRecord(cast(uint)(r * 2), 2,
            r == 2 ? Terminator.none : Terminator.lf, Span(base, 3));
    }
    doc.columnCount = 2;

    SmallBuffer!(ColumnType, 16) types;
    inferColumnTypes(doc, 100, types);
    assert(types.length == 2);
    assert(types[0] == ColumnType.text);
    assert(types[1] == ColumnType.integer);
}
