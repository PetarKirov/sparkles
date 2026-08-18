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
import sparkles.base.text.width : CellAlign = Align;
import sparkles.syntax.md.render_widgets : MdTableExtras;
import table_select : serializeTable, TableCopyFormat, TableRegion;

version (unittest) import sparkles.syntax.md.render_widgets : TableScroll;
import sparkles.dsv : applyProjection, classifyValue, ColumnType, decodeCell,
    detectHeader, Dialect, DsvDoc, inferColumnTypes, parseDsv, ProjectionSpec,
    seedForExtension, sniff, sniffMaxBytes, sniffMaxRecords;
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
    uint visibleRows;     /// data rows surviving the projection (`DSK5`)
    bool projected;       /// a non-pristine projection is showing (`DSB2`)
}

/// The presentation projection (`DSB1`): the engine's spec (which records,
/// what order) plus the host's column choice (`columns` = visible **data**
/// columns in view order; null = all, natural order). One regular value —
/// every browser surface edits it, `adaptDsv`/`DsvCopy` consume it.
struct DsvProjection
{
    ProjectionSpec spec;
    const(uint)[] columns;
    /// `DSF3`: the fuzzy remainder's per-data-record admission mask
    /// (`dsv_browser.fuzzyRowMask`), intersected AFTER the engine's
    /// constraints — filtering commutes with sorting, so the intersection
    /// preserves the projected order. null = no mask.
    const(bool)[] rowMask;

    bool pristine() const scope @safe pure nothrow @nogc
        => spec.pristine && columns is null && rowMask is null;
}

/// The adapter's product: the decoded buffer and the table model over it,
/// plus the table refinements every sink forwards (`MdViewOptions.tableExtras`
/// via `PreviewModel`): the record-number stub column (`DSG5`), the
/// per-column cap (`DSG4`), typed + decimal alignment (`DSG3`/`DSG7`), and
/// the pinned header (`DSG2`).
struct DsvAdapted
{
    DsvInfo info;
    string text; /// becomes `Document.source` / `MdDoc.source`
    MdDoc doc;
    MdTableExtras extras;
}

/// The provisional per-column content-width cap (`DSG4`).
enum size_t dsvColumnCapCells = 64;

/// Drops permutation entries the fuzzy mask rejects, in place (`DSF3`).
private void maskPermutation(ref SmallBuffer!(uint, 64) perm,
    scope const(bool)[] mask) @safe pure nothrow @nogc
{
    size_t w = 0;
    foreach (i; 0 .. perm.length)
    {
        const r = perm[i];
        if (r < mask.length && mask[r])
            perm[w++] = r;
    }
    perm.length = w;
}

/// The flags that reproduce an already-resolved dialect exactly — the
/// reprojection path re-adapts without re-sniffing (`DSB4`'s cheap half).
DsvFlags flagsOf(in DsvInfo info) @safe pure
{
    return DsvFlags(
        delimiter: [info.dialect.delimiter].idup,
        quote: [info.dialect.quote].idup,
        header: info.hasHeader ? "yes" : "no");
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
DsvAdapted adaptDsv(string original, string ext, in DsvFlags flags,
    in DsvProjection proj = DsvProjection.init) @safe
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

    // The projection resolves here (`DSB1`): the engine's permutation over
    // data records, and the host's visible-column list.
    SmallBuffer!(ColumnType, 16) types;
    inferColumnTypes(doc, sniffMaxRecords, types);
    SmallBuffer!(uint, 64) rowPerm;
    applyProjection(doc, types[], proj.spec, rowPerm);
    if (proj.rowMask !is null)
        maskPermutation(rowPerm, proj.rowMask);
    auto visCols = proj.columns !is null ? proj.columns.dup : {
        auto all = new uint[](doc.columnCount);
        foreach (c; 0 .. doc.columnCount)
            all[c] = cast(uint) c;
        return all;
    }();

    a.info = DsvInfo(
        present: true,
        dialect: dialect,
        hasHeader: hasHeader,
        syntheticHeader: !hasHeader,
        columns: doc.columnCount,
        dataRows: cast(uint) doc.dataRecordCount,
        ragged: doc.raggedCount,
        visibleRows: cast(uint) rowPerm.length,
        projected: !proj.pristine,
    );
    if (doc.columnCount == 0 || visCols.length == 0)
        return a; // empty input / all columns hidden: the caller degrades

    buildTable(a, doc, types[], rowPerm[], visCols);
    return a;
}

/// Synthesizes the decoded buffer + the `table` block tree (`DSG1` via the
/// md path) over the **projected view**: header row first (real, padded with
/// `…+N` overflow names, or fully synthetic), the permuted data rows padded
/// to the grid width (`DSM3`), per-column alignment from the inferred types
/// (`DSG3`: numeric/date right, bool center). `rowPerm` holds data-record
/// indexes in view order; `visCols` the visible data columns in view order.
private void buildTable(ref DsvAdapted a, in DsvDoc doc,
    in ColumnType[] types, in uint[] rowPerm, in uint[] visCols) @safe
{
    const cols = visCols.length;
    auto buf = appender!string;
    SmallBuffer!(char, 256) cellBuf;

    MdBlock table = { kind: MdBlockKind.table };

    // DSG3/DSG7: alignment from the sampled column types — the md-model
    // `ColAlign` for any plain consumer, and the extras' `CellAlign` overrides
    // that carry what markdown cannot say (`decimal`). Column 0 is the
    // record-number gutter (`DSG5`).
    auto aligns = new ColAlign[cols + 1];
    auto cellAligns = new CellAlign[cols + 1];
    aligns[0] = ColAlign.right;
    cellAligns[0] = CellAlign.right;
    foreach (vi, c; visCols)
    {
        final switch (c < types.length ? types[c] : ColumnType.text)
        {
        case ColumnType.integer:
        case ColumnType.date:
            aligns[vi + 1] = ColAlign.right;
            cellAligns[vi + 1] = CellAlign.right;
            break;
        case ColumnType.floating:
            aligns[vi + 1] = ColAlign.right;
            cellAligns[vi + 1] = CellAlign.decimal; // DSG7
            break;
        case ColumnType.boolean:
            aligns[vi + 1] = ColAlign.center;
            cellAligns[vi + 1] = CellAlign.center;
            break;
        case ColumnType.text:
            aligns[vi + 1] = ColAlign.none;
            cellAligns[vi + 1] = CellAlign.inherit;
            break;
        }
    }
    table.aligns = aligns;

    a.extras = MdTableExtras(
        headerCols: 1,
        columnMaxWidth: dsvColumnCapCells,
        columnAligns: cellAligns,
        pinHeader: true,
        // The record-number gutter stays put while the grid scrolls
        // horizontally (`DSG5` × the freeze-pane generalization).
        freezeLeftColumns: 1,
    );

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

    // Header row; column 0 is the gutter's own header.
    {
        auto names = new const(char)[][cols + 1];
        names[0] = "#";
        if (a.info.hasHeader)
        {
            const rec = doc.records[0];
            foreach (vi, c; visCols)
                names[vi + 1] = c < rec.cellCount
                    ? decodeCell(doc, doc.cells[rec.cellsStart + c], cellBuf).idup
                    : text("…+", c - rec.cellCount + 1); // overflow columns (DSM3)
        }
        else
            foreach (vi, c; visCols)
                names[vi + 1] = columnName(c);
        addRow(names);
    }

    // The projected data rows, padded to the grid width, gutter-numbered by
    // their 1-based SOURCE order (`DSG5` — a sorted/filtered view shows
    // provenance, never a renumbering).
    const first = a.info.hasHeader ? 1 : 0;
    foreach (dataIdx; rowPerm)
    {
        const rec = doc.records[first + dataIdx];
        auto cells = new const(char)[][cols + 1];
        cells[0] = text(dataIdx + 1);
        foreach (vi, c; visCols)
            cells[vi + 1] = c < rec.cellCount
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
    if (info.projected)
        note ~= text(" · ", info.visibleRows, "/", info.dataRows, " rows");
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

// ── Grid copy (`DSC2`/`DSC4`) ───────────────────────────────────────────────

/// Resolves `--table-copy` (`CLI11` × `DSC2`): explicit names win; `auto`
/// (the default) picks `source` for a DSV document and `tsv` otherwise.
TableCopyFormat resolveTableCopy(string name, bool isDsv) @safe
{
    import sparkles.base.logger : warning;

    switch (name)
    {
        case "markdown": return TableCopyFormat.markdown;
        case "tsv": return TableCopyFormat.tsv;
        case "source": return TableCopyFormat.source;
        case "auto", "": break;
        default:
            warning(i"unknown --table-copy '$(name)'; using 'auto'");
    }
    return isDsv ? TableCopyFormat.source : TableCopyFormat.tsv;
}

@("dsv_view.resolveTableCopy.autoByKind")
@safe unittest
{
    assert(resolveTableCopy("auto", true) == TableCopyFormat.source);
    assert(resolveTableCopy("auto", false) == TableCopyFormat.tsv);
    assert(resolveTableCopy("markdown", true) == TableCopyFormat.markdown);
    assert(resolveTableCopy("source", false) == TableCopyFormat.source);
}


/// The grid-copy side of a DSV document: raw cell bytes for the `source`
/// format (original quoting preserved — the serializer never re-quotes), the
/// whole-grid shortcut that reproduces the input byte-for-byte (`DSC4`: BOM,
/// per-record terminators, ragged rows and all), and the chrome geometry —
/// the record-number stub column and a synthetic header row are excluded
/// from every copy format (`DSG5`/`DSD3`).
struct DsvCopy
{
    string rawText; /// the original bytes ("" = not a DSV document)
    DsvInfo info;
    private DsvDoc parsed;
    private bool parsedOk;
    private uint[] rowPerm;  /// view data row → data record (`DSC5`)
    private uint[] viewCols; /// view data col → data column
    private bool projPristine = true;
    /// Decoded (or synthetic) DATA column names, for filter-name resolution
    /// and the columns palette.
    string[] headerNames;

    bool present() const @safe pure nothrow @nogc => info.present;
    /// View grid chrome: the gutter column, and the synthetic header row.
    size_t stubCols() const @safe pure nothrow @nogc => info.present ? 1 : 0;
    /// ditto
    size_t skipRows() const @safe pure nothrow @nogc
        => info.present && info.syntheticHeader ? 1 : 0;

    static DsvCopy of(string rawText, in DsvInfo info,
        in DsvProjection proj = DsvProjection.init) @safe
    {
        DsvCopy c = { rawText: rawText, info: info };
        c.projPristine = proj.pristine;
        if (info.present)
        {
            auto res = parseDsv(rawText, info.dialect);
            if (!res.hasError)
            {
                c.parsed = res.value;
                c.parsed.hasHeader = info.hasHeader;
                c.parsedOk = true;
                // The same deterministic projection the adapter rendered
                // (`DSS3` makes re-deriving it here exact), so view
                // coordinates map through it (`DSC5`: WYSIWYG).
                SmallBuffer!(ColumnType, 16) types;
                inferColumnTypes(c.parsed, sniffMaxRecords, types);
                SmallBuffer!(uint, 64) perm;
                applyProjection(c.parsed, types[], proj.spec, perm);
                if (proj.rowMask !is null)
                    maskPermutation(perm, proj.rowMask);
                c.rowPerm = perm[].dup;
                c.headerNames = new string[](c.parsed.columnCount);
                {
                    SmallBuffer!(char, 256) nameBuf;
                    const hasHdr = info.hasHeader && c.parsed.records.length;
                    foreach (col; 0 .. c.parsed.columnCount)
                    {
                        if (hasHdr && col < c.parsed.records[0].cellCount)
                            c.headerNames[col] = decodeCell(c.parsed,
                                c.parsed.cells[c.parsed.records[0].cellsStart + col],
                                nameBuf).idup;
                        else
                            c.headerNames[col] = columnName(col);
                    }
                }
                if (proj.columns !is null)
                    c.viewCols = proj.columns.dup;
                else
                {
                    c.viewCols = new uint[](c.parsed.columnCount);
                    foreach (col; 0 .. c.parsed.columnCount)
                        c.viewCols[col] = cast(uint) col;
                }
            }
        }
        return c;
    }

    /// Raw bytes of VIEW cell `(row, col)`: view column 0 is the gutter (""),
    /// view row 0 the header (synthetic → ""); data rows and columns map
    /// through the projection (`DSC5` — the copy is what the view shows),
    /// a ragged row's padded cells are "".
    const(char)[] rawCell(size_t viewRow, size_t viewCol) const @safe
    {
        if (!parsedOk || viewCol == 0 || viewCol - 1 >= viewCols.length)
            return "";
        const dataCol = viewCols[viewCol - 1];
        const first = info.hasHeader ? 1 : 0;
        size_t recIdx;
        if (viewRow == 0 && info.hasHeader)
            recIdx = 0; // the real header row
        else
        {
            const dataRow = viewRow - 1; // below the (real or synthetic) header
            if (dataRow >= rowPerm.length)
                return "";
            recIdx = first + rowPerm[dataRow];
        }
        if (recIdx >= parsed.records.length)
            return "";
        const r = parsed.records[recIdx];
        if (dataCol >= r.cellCount)
            return "";
        return parsed.cellRaw(parsed.cells[r.cellsStart + dataCol]);
    }

    /// The region covers the whole view grid of a PRISTINE projection — a
    /// `source` copy then IS the input file (`DSC4`; under a projection the
    /// copy is the visible view instead, `DSC5`).
    bool coversWholeGrid(in TableRegion reg, size_t rows, size_t cols) const
        @safe pure nothrow @nogc
        => projPristine && !reg.subCell && reg.rowLo == 0 && reg.colLo == 0
            && reg.rowHi + 1 >= rows && reg.colHi + 1 >= cols;
}

/// One serialization entry for both hosts (`TBL2`/`TBL6` × `DSC2`): DSV-aware
/// when `copy.present` (chrome exclusion in every format, raw bytes + the
/// whole-grid byte-exact shortcut under `source`), the plain path otherwise.
/// `viewCell` is the host's decoded-view accessor.
string serializeGridCopy(const DsvCopy copy, in TableRegion reg, size_t rows,
    size_t cols, scope const(char)[] delegate(size_t, size_t) @safe viewCell,
    TableCopyFormat fmt) @safe
{
    if (!copy.present)
        return serializeTable(reg, viewCell, fmt);
    if (fmt == TableCopyFormat.source && copy.coversWholeGrid(reg, rows, cols))
        return copy.rawText;
    if (fmt == TableCopyFormat.source)
        return serializeTable(reg,
            (size_t r, size_t c) @safe => copy.rawCell(r, c), fmt,
            copy.info.dialect.delimiter, copy.stubCols, copy.skipRows);
    return serializeTable(reg, viewCell, fmt, ',', copy.stubCols, copy.skipRows);
}

@("dsv_view.copy.rawCellsAndChrome")
@safe unittest
{
    const src = "name,price\n\"a,b\",\"1,5\"\nplain,27\n";
    const a = adaptDsv(src, "csv", DsvFlags());
    const copy = DsvCopy.of(src, a.info);
    assert(copy.present && copy.stubCols == 1 && copy.skipRows == 0);
    // View (row, col): row 0 header, col 0 gutter; raw bytes keep quotes.
    assert(copy.rawCell(0, 1) == "name");
    assert(copy.rawCell(1, 1) == `"a,b"`);
    assert(copy.rawCell(1, 2) == `"1,5"`);
    assert(copy.rawCell(1, 0) == ""); // gutter
    assert(copy.rawCell(9, 1) == ""); // out of range

    const(char)[] viewCell(size_t r, size_t c) @safe => "view";
    const all = TableRegion(rowLo: 0, rowHi: 2, colLo: 0, colHi: 2);
    // The whole grid under `source` IS the file.
    assert(serializeGridCopy(copy, all, 3, 3, &viewCell,
        TableCopyFormat.source) == src);
    // A partial rect re-emits raw cells in the dialect.
    const rect = TableRegion(rowLo: 1, rowHi: 2, colLo: 1, colHi: 2);
    assert(serializeGridCopy(copy, rect, 3, 3, &viewCell,
        TableCopyFormat.source) == "\"a,b\",\"1,5\"\nplain,27");
}

@("dsv_view.copy.byteExactHardCases")
@safe unittest
{
    // BOM + CRLF + ragged + unterminated-quote tolerance + no trailing
    // newline: the whole-grid `source` copy reproduces the bytes exactly.
    const src = "\xEF\xBB\xBFa,b\r\n1,2,3\n4";
    const a = adaptDsv(src, "csv", DsvFlags());
    const copy = DsvCopy.of(src, a.info);
    const rows = 1 + a.info.dataRows + (a.info.syntheticHeader ? 1 : 0) - (a.info.hasHeader ? 0 : 0);
    const dims = a.doc.root.children.length
        ? a.doc.root.children[0].children.length : 0;
    const all = TableRegion(rowLo: 0, rowHi: dims ? dims - 1 : 0,
        colLo: 0, colHi: a.info.columns); // +1 gutter − 1 inclusive
    const(char)[] viewCell(size_t r, size_t c) @safe => "";
    assert(serializeGridCopy(copy, all, dims, a.info.columns + 1, &viewCell,
        TableCopyFormat.source) == src);
}

@("dsv_view.copy.syntheticHeaderNeverSerialized")
@safe unittest
{
    const src = "1,2\n3,4\n5,6\n";
    const a = adaptDsv(src, "csv", DsvFlags());
    assert(a.info.syntheticHeader);
    const copy = DsvCopy.of(src, a.info);
    assert(copy.skipRows == 1);
    // A tsv copy spanning the synthetic header + gutter drops both.
    const(char)[] viewCell(size_t r, size_t c) @safe
    {
        // the decoded view: row 0 = "A B", data rows numbered
        static immutable string[3][4] v = [
            ["#", "A", "B"], ["1", "1", "2"], ["2", "3", "4"], ["3", "5", "6"],
        ];
        return v[r][c];
    }
    const all = TableRegion(rowLo: 0, rowHi: 3, colLo: 0, colHi: 2);
    assert(serializeGridCopy(copy, all, 4, 3, &viewCell, TableCopyFormat.tsv)
        == "1\t2\n3\t4\n5\t6");
    // And the whole grid under `source` is still the exact file.
    assert(serializeGridCopy(copy, all, 4, 3, &viewCell,
        TableCopyFormat.source) == src);
}

@("dsv_view.copy.projectedWysiwyg")
@safe unittest
{
    import sparkles.dsv : Constraint, ConstraintOp, ProjectionSpec, SortKey;

    // DSC5: under a projection, copies serialize the VISIBLE view in view
    // order — and the byte-exact whole-grid shortcut is off.
    const src = "name,qty\nb,2\na,3\nc,1\n";
    DsvProjection proj = {
        spec: ProjectionSpec([SortKey(1)], // qty asc → c(1), b(2), a(3)
            [Constraint(1, ConstraintOp.gt, false, "1")]), // qty > 1
    };
    const a = adaptDsv(src, "csv", DsvFlags(), proj);
    assert(a.info.projected && a.info.visibleRows == 2);
    // The rendered grid: header, then b(row 1, gutter "1"), a(row 2, "2").
    const table = a.doc.root.children[0];
    const r1 = table.children[1];
    assert(a.text[r1.children[0].span.start .. r1.children[0].span.end] == "1");
    assert(a.text[r1.children[1].span.start .. r1.children[1].span.end] == "b");
    const r2 = table.children[2];
    assert(a.text[r2.children[0].span.start .. r2.children[0].span.end] == "2");
    assert(a.text[r2.children[1].span.start .. r2.children[1].span.end] == "a");

    const copy = DsvCopy.of(src, a.info, proj);
    const(char)[] viewCell(size_t r, size_t c) @safe => "";
    const all = TableRegion(rowLo: 0, rowHi: 2, colLo: 0, colHi: 2);
    // Whole grid ≠ the file when projected: it is the visible view.
    assert(serializeGridCopy(copy, all, 3, 3, &viewCell,
        TableCopyFormat.source) == "name,qty\nb,2\na,3");
}

@("dsv_view.copy.hiddenColumnsExcluded")
@safe unittest
{
    // A column projection: only qty shows; source copies emit just it.
    const src = "name,qty,tag\nx,2,aa\ny,3,bb\n";
    static immutable uint[1] only = [1u];
    DsvProjection proj = { columns: only[] };
    const a = adaptDsv(src, "csv", DsvFlags(), proj);
    assert(a.info.projected);
    const hdr = a.doc.root.children[0].children[0];
    assert(hdr.children.length == 2); // gutter + qty
    assert(a.text[hdr.children[1].span.start .. hdr.children[1].span.end] == "qty");

    const copy = DsvCopy.of(src, a.info, proj);
    const(char)[] viewCell(size_t r, size_t c) @safe => "";
    const all = TableRegion(rowLo: 0, rowHi: 2, colLo: 0, colHi: 1);
    assert(serializeGridCopy(copy, all, 3, 2, &viewCell,
        TableCopyFormat.source) == "qty\n2\n3");
}

// ── Golden grids (the D1 gate) ──────────────────────────────────────────────
// The adapter's output rendered through the shared widget pipeline
// (`viewMarkdown` → `layout` → `CellGrid`) and compared as a plain glyph grid
// — the `md/goldens.d` idiom. This is the layout oracle for every cell sink
// (the GUI/TUI/ANSI arms paint this same tree); color stays out on purpose.
// Fixtures: `apps/hue/test/fixtures/dsv/<name>.csv` + `<name>.txt`.
// Regenerate after an intended change:
//
//   SPARKLES_UPDATE_GOLDENS=1 dub test :hue -- -i dsv_view.golden
//   git diff apps/hue/test/fixtures/dsv

version (unittest)
{
    private enum dsvGoldenWidth = 48;

    private string dsvGoldenDir()
    {
        import std.path : buildNormalizedPath, dirName;

        return __FILE_FULL_PATH__.dirName
            .buildNormalizedPath("../test/fixtures/dsv");
    }

    private string dsvGridText(in DsvAdapted a, int maxLines = 0,
        int scrollX = 0, int scrollY = 0) @system
    {
        import std.utf : encode;
        import sparkles.base.term_color : RgbColor, toRgb;
        import sparkles.syntax : builtinThemes, LabelSet, resolveTheme;
        import sparkles.syntax.md.render_widgets : MdViewOptions, MdViewTheme,
            viewMarkdown;
        import sparkles.ui.display_list : buildDisplayList;
        import sparkles.ui.geometry : Constraints;
        import sparkles.ui.interp.cells : CellGrid;
        import sparkles.ui.interp.immediate : paint;
        import sparkles.ui.layout : layout;
        import sparkles.ui.style : defaultTwoslashPalette;

        const labels = LabelSet.standard();
        const theme = resolveTheme(builtinThemes["catppuccin-mocha"], labels);
        const pageFg = toRgb(theme.defaults.fg, RgbColor(0xcc, 0xcc, 0xcc));
        const pageBg = toRgb(theme.defaults.bg, RgbColor(0x1e, 0x1e, 0x1e));
        MdViewOptions opt = {
            theme: MdViewTheme.derive(theme, pageFg, pageBg),
            maxWidth: dsvGoldenWidth,
            tableExtras: a.extras,
            tableMaxLines: maxLines,
            tableScrolls: [TableScroll(0, scrollX, scrollY)],
        };
        auto tree = viewMarkdown(a.doc, opt);
        auto frames = layout(tree, Constraints(maxW: dsvGoldenWidth));
        const r = frames[tree.root].rect;
        auto grid = CellGrid(r.width, r.height, pageFg, pageBg);
        paint(grid, buildDisplayList(tree, frames, defaultTwoslashPalette(),
            pageFg, pageBg));

        string out_;
        foreach (y; 0 .. grid.height)
        {
            size_t lineEnd = out_.length;
            foreach (x; 0 .. grid.width)
            {
                char[4] cbuf;
                const n = encode(cbuf, grid.cells[y * grid.width + x].glyph);
                out_ ~= cbuf[0 .. n];
                if (grid.cells[y * grid.width + x].glyph != ' ')
                    lineEnd = out_.length;
            }
            out_ = out_[0 .. lineEnd];
            out_ ~= '\n';
        }
        return out_;
    }

    private void checkDsvGolden(string name, in DsvFlags flags = DsvFlags(),
        int maxLines = 0, int scrollX = 0, int scrollY = 0) @system
    {
        import std.file : exists, readText, write;
        import std.path : buildPath;
        import std.process : environment;

        const dir = dsvGoldenDir();
        const fixture = dir.buildPath(name ~ ".csv");
        const golden = dir.buildPath(name ~ ".txt");
        const rendered = dsvGridText(adaptDsv(readText(fixture), "csv", flags),
            maxLines, scrollX, scrollY);
        if (environment.get("SPARKLES_UPDATE_GOLDENS", "").length != 0
            || !golden.exists)
        {
            write(golden, rendered);
            return;
        }
        assert(rendered == readText(golden), name ~ ": rendered grid differs "
            ~ "from " ~ name ~ ".txt — if intended, regenerate with "
            ~ "SPARKLES_UPDATE_GOLDENS=1 dub test :hue -- -i dsv_view.golden "
            ~ "and review the diff");
    }
}

@("dsv_view.golden.typed")
@system unittest
{
    checkDsvGolden("typed");
}

@("dsv_view.golden.semicolon")
@system unittest
{
    checkDsvGolden("semicolon");
}

@("dsv_view.golden.raggedSynthetic")
@system unittest
{
    checkDsvGolden("ragged-synthetic");
}

@("dsv_view.golden.tallPinnedHeader")
@system unittest
{
    // The vertical viewport engages (interior > maxLines) and the header
    // band pins below the top border (DSG2) — the right border is the track.
    checkDsvGolden("tall", DsvFlags(), maxLines: 8);
}

@("dsv_view.golden.widescrollViewport")
@system unittest
{
    // A grid wider than the 48-cell golden width: the horizontal framed
    // viewport engages (DSG4 via TBL7) — pinned corners, the bottom border
    // as the scrollbar, the interior clipped at offset 0.
    checkDsvGolden("wide");
}

@("dsv_view.golden.wideScrolledFrozenGutter")
@system unittest
{
    // The same wide grid scrolled 12 cells right: the record-number gutter
    // (and its heavy stub rule) stays frozen at the left edge while the
    // data columns scroll behind it (DSG5 × the freeze-pane emission).
    checkDsvGolden("wide-scrolled", DsvFlags(), maxLines: 0, scrollX: 12);
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
    // Column 0 is the record-number gutter (DSG5); data columns follow.
    assert(table.aligns == [ColAlign.right, ColAlign.none, ColAlign.right,
        ColAlign.right]);
    const hdr = table.children[0];
    assert(a.text[hdr.children[0].span.start .. hdr.children[0].span.end] == "#");
    assert(a.text[hdr.children[2].span.start .. hdr.children[2].span.end] == "age");
    const row1 = table.children[1];
    assert(a.text[row1.children[0].span.start .. row1.children[0].span.end] == "1");
    // The extras: stub column, cap, typed + decimal aligns, pinned header.
    assert(a.extras.headerCols == 1);
    assert(a.extras.columnMaxWidth == dsvColumnCapCells);
    assert(a.extras.pinHeader);
    assert(a.extras.columnAligns == [CellAlign.right, CellAlign.inherit,
        CellAlign.right, CellAlign.right]);
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
    assert(a.text[hdr.children[0].span.start .. hdr.children[0].span.end] == "#");
    assert(a.text[hdr.children[1].span.start .. hdr.children[1].span.end] == "A");
    const short_ = table.children[2];
    assert(short_.children.length == 4); // gutter + 3 data columns
    assert(a.text[short_.children[0].span.start .. short_.children[0].span.end] == "2");
    assert(short_.children[3].inlines.length == 0); // padded empty cell
}

@("dsv_view.adapt.decodedBufferUnquotes")
@safe
unittest
{
    // Quoted cells land decoded in the buffer: display and copy see clean
    // text (the D1 buffer decision; raw fidelity is post-CHK).
    const a = adaptDsv("h1,h2\n\"a,b\",\"say \"\"hi\"\"\"\n", "csv", DsvFlags());
    const row = a.doc.root.children[0].children[1];
    assert(a.text[row.children[1].span.start .. row.children[1].span.end] == "a,b");
    assert(a.text[row.children[2].span.start .. row.children[2].span.end] == `say "hi"`);
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
