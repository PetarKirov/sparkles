/// The D1 DSV adapter (`docs/specs/hue/dsv-preview.md`, milestone D1): turns
/// a raw DSV byte buffer into the **existing markdown table model**, so every
/// sink renders the grid through the unmodified md table path — the phase-1
/// bridge that keeps this stream out of `sparkles.ui.components.table` while
/// the table-rendering unification proceeds in a parallel worktree. The
/// checkpoint (CHK) revisits this seam.
///
/// The adapter resolves the dialect (extension seed → sniff → flag
/// overrides, `DSD1`–`DSD4`), parses with `sparkles:dsv`, and synthesizes a
/// **decoded text buffer** whose spans the `MdDoc` table indexes: the md
/// view renders and copies cell text by slicing `MdDoc.source`, so pointing
/// spans at the raw bytes would display quoted cells with their quotes. The
/// original bytes stay on the `Document` untouched — the raw-fidelity copy
/// contract (`DSC2`–`DSC5`) is post-CHK and will reconcile the two buffers.
module dsv_view;

import std.array : appender;
import std.conv : text;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.dsv : classifyValue, ColumnType, decodeCell, detectHeader,
    Dialect, DsvDoc, inferColumnTypes, parseDsv, seedForExtension, sniff,
    sniffMaxBytes, sniffMaxRecords;
import sparkles.syntax.md.model : ColAlign, MdBlock, MdBlockKind, MdDoc,
    MdInline, MdInlineKind, MdSpan = Span;

/// The `--dsv-*` flag values, raw (`DSD4`); empty string = not forced.
struct DsvFlags
{
    string delimiter; /// `--dsv-delimiter` (accepts a char, `\t`, or `tab`)
    string quote;     /// `--dsv-quote`
    string header = "auto"; /// `--dsv-header` `auto|yes|no`
}

/// What the resolution decided — the status-chrome readout's substance
/// (`DSK5`) and the `Document`'s record of the parse.
struct DsvInfo
{
    bool present;
    Dialect dialect;
    bool hasHeader;       /// the first source record is a header row
    bool syntheticHeader; /// header names are synthesized (`A B C…`, `DSD3`)
    uint columns;
    uint dataRows;
    uint ragged;          /// records off the modal column count (`DSM3`)
}

/// The adapter's product: the decoded buffer and the table model over it.
struct DsvAdapted
{
    DsvInfo info;
    string text; /// becomes `Document.source` / `MdDoc.source`
    MdDoc doc;
}

/// One flag char from its CLI spelling (`,` · `;` · `\t`/`tab` · …).
private char flagChar(string s, char fallback) @safe pure nothrow
{
    if (s == `\t` || s == "tab")
        return '\t';
    return s.length ? s[0] : fallback;
}

/// A spreadsheet-style synthetic column name: `A`…`Z`, `AA`, `AB`, …
string columnName(size_t index) @safe pure nothrow
{
    char[8] tmp;
    size_t n = tmp.length;
    size_t i = index;
    for (;;)
    {
        tmp[--n] = cast(char)('A' + i % 26);
        if (i < 26)
            break;
        i = i / 26 - 1;
    }
    return tmp[n .. $].idup;
}

/// Resolves the dialect and header per the `DSD` precedence
/// (flags > sniff > extension seed) and adapts the parsed document onto the
/// md table model. `ext` is the extension without its dot ("" for stdin).
DsvAdapted adaptDsv(string original, string ext, in DsvFlags flags) @safe
{
    DsvAdapted a;

    const seed = seedForExtension(ext);
    const sampleLen = original.length < sniffMaxBytes ? original.length : sniffMaxBytes;
    const sniffed = sniff(original[0 .. sampleLen], seed);

    Dialect dialect = sniffed.dialect;
    dialect.delimiter = flagChar(flags.delimiter, dialect.delimiter);
    dialect.quote = flagChar(flags.quote, dialect.quote);

    auto parsed = parseDsv(original, dialect);
    if (parsed.hasError)
        return a; // an unusable forced dialect: the caller keeps the raw view
    auto doc = parsed.value;

    // The sniffer's header verdict was computed under the sniffed dialect;
    // a flag override changes the grid, so re-run the heuristic on the final
    // parse (`DSD3`).
    const hasHeader = flags.header == "yes" ? true
        : flags.header == "no" ? false : detectHeader(doc);
    doc.hasHeader = hasHeader;

    a.info = DsvInfo(
        present: true,
        dialect: dialect,
        hasHeader: hasHeader,
        syntheticHeader: !hasHeader,
        columns: doc.columnCount,
        dataRows: cast(uint) doc.dataRecordCount,
        ragged: doc.raggedCount,
    );
    if (doc.columnCount == 0)
        return a; // empty input: no table (the caller degrades, DSM3)

    buildTable(a, doc);
    return a;
}

/// Synthesizes the decoded buffer + the `table` block tree (`DSG1` via the
/// md path): header row first (real, padded with `…+N` overflow names, or
/// fully synthetic), data rows padded to the grid width (`DSM3`), per-column
/// alignment from the inferred types (`DSG3`: numeric/date right, bool
/// center).
private void buildTable(ref DsvAdapted a, in DsvDoc doc) @safe
{
    const cols = doc.columnCount;
    auto buf = appender!string;
    SmallBuffer!(char, 256) cellBuf;

    MdBlock table = { kind: MdBlockKind.table };

    // DSG3: alignment from the sampled column types.
    SmallBuffer!(ColumnType, 16) types;
    inferColumnTypes(doc, sniffMaxRecords, types);
    auto aligns = new ColAlign[cols];
    foreach (c; 0 .. cols)
    {
        final switch (c < types.length ? types[c] : ColumnType.text)
        {
        case ColumnType.integer:
        case ColumnType.floating:
        case ColumnType.date:
            aligns[c] = ColAlign.right;
            break;
        case ColumnType.boolean:
            aligns[c] = ColAlign.center;
            break;
        case ColumnType.text:
            aligns[c] = ColAlign.none;
            break;
        }
    }
    table.aligns = aligns;

    // One row into the buffer + tree; texts are already decoded.
    void addRow(scope const(char)[][] cells)
    {
        MdBlock row = { kind: MdBlockKind.tableRow };
        const rowStart = buf[].length;
        row.children = new MdBlock[cells.length];
        foreach (ci, cellText; cells)
        {
            if (ci)
                buf ~= a.info.dialect.delimiter;
            const start = buf[].length;
            buf ~= cellText;
            const span = MdSpan(start, buf[].length);
            MdBlock cell = { kind: MdBlockKind.tableCell, span: span };
            if (span.end > span.start)
                cell.inlines = [MdInline(MdInlineKind.text, span)];
            row.children[ci] = cell;
        }
        row.span = MdSpan(rowStart, buf[].length);
        buf ~= '\n';
        table.children ~= row;
    }

    // Header row.
    {
        auto names = new const(char)[][cols];
        if (a.info.hasHeader)
        {
            const rec = doc.records[0];
            foreach (c; 0 .. cols)
                names[c] = c < rec.cellCount
                    ? decodeCell(doc, doc.cells[rec.cellsStart + c], cellBuf).idup
                    : text("…+", c - rec.cellCount + 1); // overflow columns (DSM3)
        }
        else
            foreach (c; 0 .. cols)
                names[c] = columnName(c);
        addRow(names);
    }

    // Data rows, padded to the grid width.
    const first = a.info.hasHeader ? 1 : 0;
    foreach (r; first .. doc.records.length)
    {
        const rec = doc.records[r];
        auto cells = new const(char)[][cols];
        foreach (c; 0 .. cols)
            cells[c] = c < rec.cellCount
                ? decodeCell(doc, doc.cells[rec.cellsStart + c], cellBuf).idup
                : "";
        addRow(cells);
    }

    a.text = buf[];
    table.span = MdSpan(0, a.text.length);
    MdBlock root = { kind: MdBlockKind.document, span: table.span };
    root.children = [table];
    a.doc = MdDoc(root, a.text);
}

/// The `DSK5` dialect readout for the status chrome, e.g.
/// `dsv · semicolon · header · 2 ragged`.
string dsvStatusNote(in DsvInfo info) @safe pure
{
    if (!info.present)
        return "";
    string delim;
    switch (info.dialect.delimiter)
    {
    case ',': delim = "comma"; break;
    case ';': delim = "semicolon"; break;
    case '\t': delim = "tab"; break;
    case '|': delim = "pipe"; break;
    default: delim = text("'", info.dialect.delimiter, "'");
    }
    auto note = text("dsv · ", delim,
        info.dialect.quote == '"' ? "" : text(" · quote ", info.dialect.quote),
        info.hasHeader ? " · header" : " · no header");
    if (info.ragged)
        note ~= text(" · ", info.ragged, " ragged");
    return note;
}

/// True when extension-less content should open as DSV (`DSD5`): the caller
/// gates on "no better kind claimed it" (no language flag, not a patch).
bool contentLooksDsv(const(char)[] sourceText) @safe pure nothrow @nogc
{
    const sampleLen = sourceText.length < sniffMaxBytes ? sourceText.length : sniffMaxBytes;
    return sniff(sourceText[0 .. sampleLen]).looksDsv;
}

@("dsv_view.columnName.spreadsheetLetters")
@safe pure
unittest
{
    assert(columnName(0) == "A");
    assert(columnName(25) == "Z");
    assert(columnName(26) == "AA");
    assert(columnName(27) == "AB");
    assert(columnName(701) == "ZZ");
    assert(columnName(702) == "AAA");
}

@("dsv_view.adapt.headerGridAndAligns")
@safe
unittest
{
    const a = adaptDsv("name,age,when\nalice,31,2026-08-18\nbob,42,2026-01-02\n",
        "csv", DsvFlags());
    assert(a.info.present && a.info.hasHeader && !a.info.syntheticHeader);
    assert(a.info.columns == 3 && a.info.dataRows == 2 && a.info.ragged == 0);
    const table = a.doc.root.children[0];
    assert(table.kind == MdBlockKind.table);
    assert(table.children.length == 3); // header + 2 data rows
    assert(table.aligns == [ColAlign.none, ColAlign.right, ColAlign.right]);
    // The first row is the header (the md table convention).
    const hdr = table.children[0];
    assert(a.text[hdr.children[1].span.start .. hdr.children[1].span.end] == "age");
}

@("dsv_view.adapt.syntheticHeaderAndPadding")
@safe
unittest
{
    // Headerless + one short record: synthetic names, padded cells (DSM3).
    const a = adaptDsv("1,2,3\n4,5\n6,7,8\n", "csv", DsvFlags());
    assert(!a.info.hasHeader && a.info.syntheticHeader);
    assert(a.info.ragged == 1);
    const table = a.doc.root.children[0];
    assert(table.children.length == 4); // synthetic header + 3 data rows
    const hdr = table.children[0];
    assert(a.text[hdr.children[0].span.start .. hdr.children[0].span.end] == "A");
    const short_ = table.children[2];
    assert(short_.children.length == 3);
    assert(short_.children[2].inlines.length == 0); // padded empty cell
}

@("dsv_view.adapt.decodedBufferUnquotes")
@safe
unittest
{
    // Quoted cells land decoded in the buffer: display and copy see clean
    // text (the D1 buffer decision; raw fidelity is post-CHK).
    const a = adaptDsv("h1,h2\n\"a,b\",\"say \"\"hi\"\"\"\n", "csv", DsvFlags());
    const row = a.doc.root.children[0].children[1];
    assert(a.text[row.children[0].span.start .. row.children[0].span.end] == "a,b");
    assert(a.text[row.children[1].span.start .. row.children[1].span.end] == `say "hi"`);
}

@("dsv_view.adapt.flagOverridesRerunHeaderHeuristic")
@safe
unittest
{
    // Semicolon content under a forced comma delimiter: one column; forcing
    // the delimiter back and the header off must both stick (DSD4).
    const forced = adaptDsv("a;1\nb;2\nc;3\n", "csv",
        DsvFlags(delimiter: ";", header: "no"));
    assert(forced.info.dialect.delimiter == ';');
    assert(!forced.info.hasHeader);
    assert(forced.info.columns == 2 && forced.info.dataRows == 3);

    const tab = adaptDsv("x\ty\n1\t2\n", "csv", DsvFlags(delimiter: `\t`));
    assert(tab.info.dialect.delimiter == '\t');
    assert(tab.info.columns == 2);
}

@("dsv_view.adapt.emptyAndUnusable")
@safe
unittest
{
    const empty = adaptDsv("", "csv", DsvFlags());
    assert(empty.info.present && empty.info.columns == 0);
    assert(empty.doc.root.children.length == 0); // no table: caller degrades

    // delimiter == quote is an unusable dialect: not present → raw view.
    const bad = adaptDsv("a,b\n", "csv", DsvFlags(delimiter: `"`));
    assert(!bad.info.present);
}

@("dsv_view.dsvStatusNote.readout")
@safe
unittest
{
    DsvInfo info = {
        present: true, dialect: Dialect(';'), hasHeader: true, ragged: 2,
    };
    assert(dsvStatusNote(info) == "dsv · semicolon · header · 2 ragged");
    info.dialect = Dialect('\t', '\'');
    info.hasHeader = false;
    info.ragged = 0;
    assert(dsvStatusNote(info) == "dsv · tab · quote ' · no header");
    assert(dsvStatusNote(DsvInfo.init) == "");
}

@("dsv_view.contentLooksDsv.gate")
@safe pure
unittest
{
    assert(contentLooksDsv("a,b\n1,2\n3,4\n"));
    assert(!contentLooksDsv("Just prose.\nMore, prose here.\nAnd a third line.\n"));
}
