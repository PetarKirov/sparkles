/// Dialect detection (`DSD*` in `docs/specs/hue/dsv-preview.md`), over a
/// caller-bounded **sample** (the [sniffMaxBytes]/[sniffMaxRecords]
/// constants are the recommended bounds — the sniffer never reads more than
/// it is handed):
///
/// $(LIST
///     $(ITEM the **delimiter** by field-count consistency across sample
///         records, quote-aware, over the candidate set `{, ; \t |}` —
///         which is what catches the semicolon CSVs European Excel writes
///         into `.csv` (`DSD1`); the extension **seeds** tie-breaks)
///     $(ITEM the **quote character**: `"` unless `'` pairs consistently
///         and `"` does not (`DSD2`))
///     $(ITEM the **header heuristic**: a typed body column whose first-row
///         cell does not satisfy the type votes header; a first row
///         carrying typed values votes data; an all-text table falls back
///         to unique-non-empty first-row names (`DSD3`))
///     $(ITEM the **DSV acceptance** signal for `.txt`/extensionless/stdin
///         content detection: ≥ 2 modal columns at ≥ 90% consistency over
///         ≥ 3 records (`DSD5`))
/// )
///
/// Flag precedence (`DSD4`) is the host's: hue overrides any sniffed
/// decision before parsing the full document.
module sparkles.dsv.dialect;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.dsv.model : classifyValue, ColumnType, decodeCell, Dialect,
    DsvDoc, inferColumnTypesFrom, satisfies, ValueKind;
import sparkles.dsv.parse : parseDsv;

/// Recommended sample bounds (`DSD` preamble; provisional, shared with
/// width measurement `DSN3`): the first 100 records or 256 KiB, whichever
/// ends first. Bounding is the caller's job — pass `source[0 .. min($, sniffMaxBytes)]`.
enum size_t sniffMaxBytes = 256 * 1024;
/// ditto
enum size_t sniffMaxRecords = 100;

/// Acceptance thresholds (`DSD1`/`DSD5`).
enum uint minConsistencyPercent = 90;
/// ditto
enum size_t minDsvRecords = 3;

/// The extension-seeded dialect (`DSD1`): `csv` → `,` · `tsv` → tab ·
/// `psv` → `|` · `ssv` → `;`; anything else seeds comma. A leading dot and
/// ASCII case are ignored.
Dialect seedForExtension(scope const(char)[] ext) @safe pure nothrow @nogc
{
    if (ext.length > 0 && ext[0] == '.')
        ext = ext[1 .. $];
    char[3] low;
    if (ext.length != 3)
        return Dialect(',');
    foreach (i; 0 .. 3)
        low[i] = cast(char)(ext[i] | 0x20);
    if (low == "tsv")
        return Dialect('\t');
    if (low == "psv")
        return Dialect('|');
    if (low == "ssv")
        return Dialect(';');
    return Dialect(',');
}

/// What [sniff] decided, and the evidence behind it.
struct SniffResult
{
    /// The winning delimiter/quote pair.
    Dialect dialect;
    /// The header heuristic's verdict (`DSD3`) — `HeaderMode.auto_`'s answer;
    /// forced modes ignore it.
    bool hasHeader;
    /// The `DSD5` acceptance signal: the sample looks like DSV at all
    /// (≥ 2 modal columns, ≥ [minConsistencyPercent] consistent,
    /// ≥ [minDsvRecords] records). Extension-selected documents render
    /// regardless; content detection requires it.
    bool looksDsv;
    /// Records in the sample under the winning dialect.
    uint sampleRecords;
    /// The modal column count under the winning dialect.
    uint modalColumns;
}

private struct DelimScore
{
    uint records;
    uint modalRecords; // records at the modal column count
    uint modalColumns;

    bool qualified() const @safe pure nothrow @nogc
        => records > 0 && modalColumns >= 2
            && modalRecords * 100 >= records * minConsistencyPercent;

    /// Rational compare of modal fractions: this > other.
    bool fractionAbove(in DelimScore o) const @safe pure nothrow @nogc
        => cast(ulong) modalRecords * o.records > cast(ulong) o.modalRecords * records;

    bool fractionEqual(in DelimScore o) const @safe pure nothrow @nogc
        => cast(ulong) modalRecords * o.records == cast(ulong) o.modalRecords * records;
}

private DelimScore scoreDialect(const(char)[] sample, in Dialect d)
    @safe pure nothrow @nogc
{
    auto res = parseDsv(sample, d);
    if (res.hasError)
        return DelimScore(0, 0, 0);
    const doc = res.value;
    return DelimScore(cast(uint) doc.records.length,
        cast(uint)(doc.records.length - doc.raggedCount), doc.modalColumnCount);
}

/// Sniffs delimiter, quote, and header presence from `sample` (`DSD1`–
/// `DSD3`, `DSD5`). `seed` is the extension-seeded dialect ([seedForExtension]);
/// its delimiter breaks scoring ties and is the fallback when no candidate
/// qualifies.
SniffResult sniff(const(char)[] sample, in Dialect seed = Dialect(','))
    @safe pure nothrow @nogc
{
    // 1. Delimiter (`DSD1`): most consistent field count wins; ties break
    //    to the seed, then to candidate order.
    static immutable char[4] candidates = [',', ';', '\t', '|'];
    char bestDelim = seed.delimiter;
    DelimScore bestScore;
    bool haveBest = false;
    foreach (cand; candidates)
    {
        const s = scoreDialect(sample, Dialect(cand, '"'));
        if (!s.qualified)
            continue;
        // A strictly better fraction wins; on an exact tie only the seed
        // displaces the incumbent (so otherwise the first candidate in set
        // order stays ahead).
        if (!haveBest || s.fractionAbove(bestScore)
            || (s.fractionEqual(bestScore) && cand == seed.delimiter))
        {
            bestDelim = cand;
            bestScore = s;
            haveBest = true;
        }
    }
    // A delimiter the candidate set does not contain (a forced exotic one)
    // never wins here; hue forces it via `DSD4` instead.

    // 2. Quote (`DSD2`): `"` unless `'` pairs consistently and `"` does not.
    char quote = '"';
    {
        const dq = quoteEvidence(sample, Dialect(bestDelim, '"'));
        const sq = quoteEvidence(sample, Dialect(bestDelim, '\''));
        if (sq.quotedCells > 0 && !sq.unterminated
            && (dq.quotedCells == 0 || dq.unterminated))
            quote = '\'';
    }

    // 3. Final parse for header + acceptance.
    SniffResult r;
    r.dialect = Dialect(bestDelim, quote);
    auto res = parseDsv(sample, r.dialect);
    if (res.hasError)
        return r;
    auto doc = res.value;
    r.sampleRecords = cast(uint) doc.records.length;
    r.modalColumns = doc.modalColumnCount;
    const modalRecords = cast(uint)(doc.records.length - doc.raggedCount);
    r.looksDsv = doc.records.length >= minDsvRecords && doc.modalColumnCount >= 2
        && modalRecords * 100 >= doc.records.length * minConsistencyPercent;
    r.hasHeader = detectHeader(doc);
    return r;
}

private struct QuoteEvidence
{
    uint quotedCells;
    bool unterminated;
}

private QuoteEvidence quoteEvidence(const(char)[] sample, in Dialect d)
    @safe pure nothrow @nogc
{
    auto res = parseDsv(sample, d);
    if (res.hasError)
        return QuoteEvidence(0, true);
    const doc = res.value;
    uint quoted = 0;
    foreach (i; 0 .. doc.cells.length)
        if (doc.cells[i].needsDecode)
            quoted++;
    return QuoteEvidence(quoted, doc.unterminatedQuote);
}

/// The `DSD3` header heuristic over an already-parsed sample document.
/// Votes, in order of strength:
/// $(LIST
///     $(ITEM any first-row cell that itself satisfies a typed **body**
///         column's type — or classifies typed while its column does — is
///         evidence the first row is **data**: no header)
///     $(ITEM a typed body column whose (non-empty) first-row cell does
///         $(B not) satisfy the type is evidence of a **header**)
///     $(ITEM an all-text table falls back to: header iff the first row's
///         cells are all non-empty, all classify as text, and are unique)
/// )
/// A single-record document uses the fallback rule alone.
bool detectHeader(in DsvDoc doc) @safe pure nothrow @nogc
{
    if (doc.records.length == 0 || doc.records[0].cellCount == 0)
        return false;
    const first = doc.records[0];

    if (doc.records.length > 1)
    {
        // Body column types: sample from record 1 on.
        SmallBuffer!(ColumnType, 16) types;
        inferColumnTypesFrom(doc, 1, sniffMaxRecords, types);

        bool headerVote = false;
        SmallBuffer!(char, 256) buf;
        foreach (col; 0 .. first.cellCount)
        {
            if (col >= types.length || types[col] == ColumnType.text)
                continue;
            const k = classifyValue(decodeCell(doc, doc.cells[first.cellsStart + col], buf));
            if (k == ValueKind.empty)
                continue; // an empty cell is evidence of nothing
            if (satisfies(k, types[col]))
                return false; // the first row carries data
            headerVote = true;
        }
        if (headerVote)
            return true;
        // No typed columns (or none decisive): fall through to the
        // all-text rule.
    }

    // Fallback: unique, non-empty, all-text first row reads as names.
    SmallBuffer!(char, 256) bufA, bufB;
    foreach (col; 0 .. first.cellCount)
    {
        const t = decodeCell(doc, doc.cells[first.cellsStart + col], bufA);
        if (classifyValue(t) != ValueKind.text)
            return false;
        foreach (other; 0 .. col)
            if (t == decodeCell(doc, doc.cells[first.cellsStart + other], bufB))
                return false;
    }
    return true;
}

@("dialect.seedForExtension")
@safe pure nothrow @nogc
unittest
{
    assert(seedForExtension(".csv").delimiter == ',');
    assert(seedForExtension("csv").delimiter == ',');
    assert(seedForExtension(".TSV").delimiter == '\t');
    assert(seedForExtension(".psv").delimiter == '|');
    assert(seedForExtension(".ssv").delimiter == ';');
    assert(seedForExtension(".log").delimiter == ',');
    assert(seedForExtension("").delimiter == ',');
}

@("dialect.sniff.semicolonCsv")
@safe pure nothrow @nogc
unittest
{
    // European Excel: semicolon delimiter, decimal commas — the comma's
    // field counts vary per row, the semicolon's are consistent (DSD1).
    const r = sniff("name;price\na;1,5\nb;27\nc;3,25\n", seedForExtension(".csv"));
    assert(r.dialect.delimiter == ';');
    assert(r.looksDsv);
    assert(r.hasHeader);
}

@("dialect.sniff.seedBreaksTies")
@safe pure nothrow @nogc
unittest
{
    // Only commas present: comma qualifies, others see one column.
    const r = sniff("a,b\n1,2\n3,4\n", seedForExtension(".csv"));
    assert(r.dialect.delimiter == ',');
    assert(r.modalColumns == 2);

    // Tab-only content under a .tsv seed.
    const t = sniff("a\tb\n1\t2\n3\t4\n", seedForExtension(".tsv"));
    assert(t.dialect.delimiter == '\t');
}

@("dialect.sniff.pipe")
@safe pure nothrow @nogc
unittest
{
    const r = sniff("a|b|c\n1|2|3\n4|5|6\n", seedForExtension(".psv"));
    assert(r.dialect.delimiter == '|');
    assert(r.modalColumns == 3);
    assert(r.looksDsv);
}

@("dialect.sniff.singleQuoteWins")
@safe pure nothrow @nogc
unittest
{
    // Consistently '-quoted cells, no double quotes anywhere (DSD2).
    const r = sniff("'a;1';x\n'b;2';y\n'c;3';z\n", Dialect(';'));
    assert(r.dialect.delimiter == ';');
    assert(r.dialect.quote == '\'');
}

@("dialect.sniff.doubleQuoteDefault")
@safe pure nothrow @nogc
unittest
{
    // Apostrophes in content must not flip the quote char: "it's" opens a
    // '-quoted segment that never closes (unterminated under ').
    const r = sniff("note,who\n\"a, b\",tom\nit's fine,ann\nplain,joe\n", Dialect(','));
    assert(r.dialect.quote == '"');
}

@("dialect.sniff.proseRejected")
@safe pure nothrow @nogc
unittest
{
    const r = sniff("Just some text.\nAnother line, with a comma.\nThird line here.\n",
        Dialect(','));
    assert(!r.looksDsv);
    assert(r.dialect.delimiter == ','); // fell back to the seed
}

@("dialect.header.typedColumns")
@safe pure nothrow @nogc
unittest
{
    // "age" over an integer body column → header (DSD3).
    const withHeader = sniff("name,age\nalice,31\nbob,42\ncarol,29\n");
    assert(withHeader.hasHeader);

    // First row already carries typed data → no header.
    const noHeader = sniff("alice,31\nbob,42\ncarol,29\n");
    assert(!noHeader.hasHeader);
}

@("dialect.header.allTextFallback")
@safe pure nothrow @nogc
unittest
{
    // No typed columns: unique non-empty text first row reads as names
    // (the documented fallback; an all-text body accepts a false positive).
    const r = sniff("name,city\nalice,paris\nbob,rome\ncarol,oslo\n");
    assert(r.hasHeader);

    // A duplicated first-row cell disqualifies it.
    const dup = sniff("x,x\naa,bb\ncc,dd\nee,ff\n");
    assert(!dup.hasHeader);
}

@("dialect.header.headerOnlyFile")
@safe pure nothrow @nogc
unittest
{
    const r = sniff("name,age,city\n");
    assert(r.hasHeader); // unique all-text single record reads as a header
    assert(!r.looksDsv); // but 1 record is below the DSD5 floor
}
