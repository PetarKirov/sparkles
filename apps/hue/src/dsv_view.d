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

import sparkles.base.buffer : SharedBuffer;
import sparkles.base.text.width : CellAlign = Align;
import sparkles.source_view.markdown : MdTableExtras;
import table_select : serializeTable, TableCopyFormat, TableRegion;

version (unittest) import sparkles.source_view.markdown : TableScroll;
import sparkles.dsv : applyProjection, classifyValue, ColumnType, decodeCell,
    detectHeader, Dialect, DsvDoc, inferColumnTypes, parseDsv, ProjectionSpec,
    seedForExtension, sniff, sniffMaxBytes, sniffMaxRecords, SortKey;
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
    /// `DSN4`: the materialized slice of the projected view. `windowRows`
    /// is 0 for a whole-view adaptation (every sink that is not a scrolling
    /// grid — `--html`, the goldens, copy). When it is set, the built
    /// document holds `windowRows` data rows starting at `windowStart` of
    /// the projected order, and `visibleRows` remains the VIRTUAL total the
    /// scrollbar and the status chrome report.
    uint windowStart;
    uint windowRows;      /// ditto — 0 = the whole projected view

    /// The data rows the built document actually carries.
    uint materializedRows() const @safe pure nothrow @nogc
        => windowRows == 0 ? visibleRows
            : (windowStart >= visibleRows ? 0
                : (visibleRows - windowStart < windowRows
                    ? visibleRows - windowStart : windowRows));
}

/// `DSN4`: the row window a scrolling grid materializes. `rows == 0` asks
/// for the whole projected view — the shape every non-scrolling sink uses.
struct DsvWindow
{
    uint start;
    uint rows;

    /// `true` when this asks for everything (the default).
    bool whole() const @safe pure nothrow @nogc => rows == 0;
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

/**
`DSN7`: the persistent half of the pipeline — everything a scroll does **not**
change.

`DSN4` bounded the build to a window of rows, but every window change still
re-derived the model that window is a slice of: a re-sniff, a re-parse and a
re-projection of the whole file, plus a second parse inside `DsvCopy` and a
third inside the fuzzy filter. Measured over a 3012-row file that was 11 ms of
a 16 ms scroll notch against 4.8 ms of actual view rebuilding — and 26 ms more
whenever a sort was engaged, because the same permutation was recomputed
identically on every notch.

This is the [model protocol](../../docs/research/ui-virtualization/concepts.md)
every framework that virtualizes properly has and hue did not: the model
outlives the view, and the window is a **query against it** rather than a
pipeline that reproduces it. The dialect, the parse, the column types and the
header names are functions of the bytes; the row permutation is a function of
the projection. None of them is a function of the scroll offset.

Held by reference (a `class`) for two reasons: it must outlive every window
built from it, and a `DsvDoc` owns reference-counted storage that there is no
reason to copy per frame.
*/
final class DsvModel
{
    private string source_;
    private DsvFlags flags_;
    private DsvInfo base_;
    private DsvDoc doc_;
    private bool usable_;
    private SharedBuffer!(ColumnType, 16) types_;
    private string[] headerNames_;

    // The memoized projection (`DSN7`): the permutation, and the projection it
    // was computed for. `rowMask` is compared by slice identity, which is exact
    // because the mask is itself memoized below — a filter that did not change
    // hands back the same slice.
    private uint[] perm_;
    private ProjectionSpec permSpec_;
    private const(bool)[] permMask_;
    private bool permValid_;

    // The memoized fuzzy row mask. Computing it needs `sparkles:fuzzy`, which
    // this module does not depend on, so `dsv_browser.rowMaskFor` computes and
    // deposits it; the model only owns the memo.
    private const(string)[] maskParts_;
    private const(bool)[] mask_;
    private bool maskValid_;

    private this() @safe {}

    /**
    Resolves the dialect and header per the `DSD` precedence (flags > sniff >
    extension seed), parses, and samples the column types. `ext` is the
    extension without its dot ("" for stdin).
    */
    static DsvModel of(string source, string ext, in DsvFlags flags) @safe
    {
        auto m = new DsvModel;
        m.source_ = source;
        // Copied, not aliased: `-preview=in` makes `flags` `scope const`, and
        // the model outlives the caller's frame.
        m.flags_ = DsvFlags(delimiter: flags.delimiter.idup,
            quote: flags.quote.idup, header: flags.header.idup);

        // `DSN7`: a sniff whose verdict is entirely overridden is a 256 KiB
        // scan for nothing. `Dialect` is exactly (delimiter, quote), so when
        // both are forced the sniffer cannot contribute — which is precisely
        // the case every replay hits, since `flagsOf` always sets both.
        Dialect dialect;
        if (flags.delimiter.length && flags.quote.length)
        {
            dialect.delimiter = flagChar(flags.delimiter, dialect.delimiter);
            dialect.quote = flagChar(flags.quote, dialect.quote);
        }
        else
        {
            const seed = seedForExtension(ext);
            const sampleLen = source.length < sniffMaxBytes
                ? source.length : sniffMaxBytes;
            const sniffed = sniff(source[0 .. sampleLen], seed);
            dialect = sniffed.dialect;
            dialect.delimiter = flagChar(flags.delimiter, dialect.delimiter);
            dialect.quote = flagChar(flags.quote, dialect.quote);
        }

        // Scoped deliberately. `DsvDoc`'s record and cell arenas are
        // reference-counted copy-on-write `SmallBuffer`s, so while BOTH the
        // `Expected` and the model hold the document its buffers have a
        // refcount of two — and the next mutable access clones all of them.
        // At the `DSN6` target that is a ~100 MB copy nobody asked for. Ending
        // the parse result's lifetime here drops the count back to one, and
        // the work below mutates a document it solely owns.
        {
            auto parsed = parseDsv(source, dialect);
            if (parsed.hasError)
                return m; // unusably forced dialect: the caller keeps the raw view
            m.doc_ = parsed.value;
        }

        // The sniffer's header verdict was computed under the sniffed dialect;
        // a flag override changes the grid, so re-run the heuristic on the
        // final parse (`DSD3`).
        const hasHeader = flags.header == "yes" ? true
            : flags.header == "no" ? false : detectHeader(m.doc_);
        m.doc_.hasHeader = hasHeader;
        m.usable_ = true;

        inferColumnTypes(m.doc_, sniffMaxRecords, m.types_);

        m.base_ = DsvInfo(
            present: true,
            dialect: dialect,
            hasHeader: hasHeader,
            syntheticHeader: !hasHeader,
            columns: m.doc_.columnCount,
            dataRows: cast(uint) m.doc_.dataRecordCount,
            ragged: m.doc_.raggedCount,
        );

        m.headerNames_ = new string[](m.doc_.columnCount);
        SharedBuffer!(char, 256) nameBuf;
        const hasNames = hasHeader && m.doc_.records.length;
        foreach (col; 0 .. m.doc_.columnCount)
            m.headerNames_[col] = hasNames && col < m.doc_.records[0].cellCount
                ? decodeCell(m.doc_,
                    m.doc_.cells[m.doc_.records[0].cellsStart + col],
                    nameBuf).idup
                : columnName(col);
        return m;
    }

    /// Whether this model already describes exactly these bytes under exactly
    /// these flags — the reuse test. The source is compared by **slice
    /// identity**, not by content: a reload produces a different buffer and
    /// must re-resolve even when the bytes happen to match.
    bool describes(string source, in DsvFlags flags) const @safe pure nothrow @nogc
        => source_.ptr is source.ptr && source_.length == source.length
            && flags_ == flags;

    /// The parse succeeded and the grid is renderable.
    bool usable() const @safe pure nothrow @nogc => usable_;
    /// The resolved facts that do not depend on a projection or a window.
    DsvInfo baseInfo() const @safe pure nothrow @nogc => base_;
    /// ditto
    string source() const @safe pure nothrow @nogc => source_;
    /// The parsed document. Borrowed — it lives as long as this model.
    ref const(DsvDoc) document() const @safe pure nothrow @nogc return => doc_;
    /// The sampled per-column types (`DSG3`).
    const(ColumnType)[] columnTypes() const @safe pure nothrow @nogc => types_[];
    /// Decoded (or synthetic) DATA column names, for filter-name resolution
    /// and the columns palette.
    const(string)[] headerNames() const @safe pure nothrow @nogc => headerNames_;

    /**
    The projected order — data-record indexes in view order — memoized.

    A scroll changes the window, never the projection, so this is the call that
    turns a sorted 3 k-row file from 26 ms per notch into a slice return. Sort
    and filter still pay in full, once, when they actually change.
    */
    const(uint)[] permutation(in DsvProjection proj) @safe
    {
        if (!usable_)
            return null;
        if (permValid_ && sameSpec(permSpec_, proj.spec)
            && permMask_ == proj.rowMask)
            return perm_;

        SharedBuffer!(uint, 64) perm;
        applyProjection(doc_, types_[], proj.spec, perm);
        if (proj.rowMask !is null)
            maskPermutation(perm, proj.rowMask);
        perm_ = perm[].dup;
        // The key is COPIED. `-preview=in` makes `proj` `scope const`, and a
        // memo that aliased the caller's slices would outlive them; the copies
        // are a few sort keys and one bool per row, paid only when the
        // projection actually changes — never on a scroll.
        permSpec_ = ProjectionSpec(sortKeys: proj.spec.sortKeys.dup,
            constraints: proj.spec.constraints.dup);
        permMask_ = proj.rowMask.dup;
        permValid_ = true;
        return perm_;
    }

    /// The memoized fuzzy row mask for `parts`, or `null` when this model holds
    /// none for them. `parts` is compared by content — it is rebuilt from the
    /// filter text on every keystroke, so identity would never hit.
    const(bool)[] cachedRowMask(const(string)[] parts) const @safe pure nothrow
        => hasCachedRowMask(parts) ? mask_ : null;

    /// Whether a memo exists for `parts` — distinct from the memo being
    /// `null`, which is what an unparseable query legitimately yields.
    bool hasCachedRowMask(const(string)[] parts) const @safe pure nothrow
        => maskValid_ && maskParts_ == parts;

    /// Deposits a freshly computed mask for `parts` and returns it, so the
    /// caller can write `return model.cacheRowMask(parts, compute())`.
    const(bool)[] cacheRowMask(const(string)[] parts, const(bool)[] mask)
        @safe pure nothrow
    {
        maskParts_ = parts.dup;
        mask_ = mask;
        maskValid_ = true;
        return mask_;
    }
}

/// `model` when it already describes exactly these bytes under these flags,
/// otherwise a freshly resolved one (`DSN7`). This one-line reuse test is what
/// makes a scroll free: the document has not changed, so nothing above the
/// window needs re-deriving.
DsvModel modelFor(DsvModel model, string source, string ext, in DsvFlags flags)
    @safe
    => model !is null && model.describes(source, flags)
        ? model : DsvModel.of(source, ext, flags);

/// Projection-spec equality for the memo. `ProjectionSpec` holds slices, so
/// `==` would compare them by content anyway — this exists to say which
/// fields the memo depends on, and to stay `@nogc`-friendly.
private bool sameSpec(in ProjectionSpec a, in ProjectionSpec b)
    @safe pure nothrow @nogc
{
    if (a.sortKeys.length != b.sortKeys.length
        || a.constraints.length != b.constraints.length)
        return false;
    foreach (i, ref k; a.sortKeys)
        if (k != b.sortKeys[i])
            return false;
    foreach (i, ref c; a.constraints)
        if (c != b.constraints[i])
            return false;
    return true;
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

/// `DSS1`'s rank chrome is reserved, not measured: a header cell keeps this
/// many cells for its sort badge whether or not it is currently sorted, so
/// engaging a sort cannot widen the column under the reader. Two cells is
/// the badge's own width — `" ▲"` for one key, `"1▲"` for a ranked one.
enum size_t dsvSortBadgeCells = 2;

/// The provisional per-column content-width cap (`DSG4`).
enum size_t dsvColumnCapCells = 64;

/// Drops permutation entries the fuzzy mask rejects, in place (`DSF3`).
private void maskPermutation(ref SharedBuffer!(uint, 64) perm,
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
    in DsvProjection proj = DsvProjection.init,
    in DsvWindow window = DsvWindow.init) @safe
    => adaptDsv(DsvModel.of(original, ext, flags), proj, window);

/**
`DSN7`: the same adaptation as a **query against a retained model** — the form
every scrolling caller uses. The window selects rows; nothing here re-derives
what the model already holds.
*/
DsvAdapted adaptDsv(DsvModel model, in DsvProjection proj = DsvProjection.init,
    in DsvWindow window = DsvWindow.init) @safe
in (model !is null)
{
    DsvAdapted a;
    if (!model.usable)
        return a; // an unusable forced dialect: the caller keeps the raw view

    ref const(DsvDoc) doc() @safe pure nothrow @nogc => model.document;

    // The projection resolves here (`DSB1`): the engine's permutation over
    // data records — memoized on the model, so a scroll pays nothing for it —
    // and the host's visible-column list.
    const rowPerm = model.permutation(proj);
    auto visCols = proj.columns !is null ? proj.columns.dup : {
        auto all = new uint[](doc.columnCount);
        foreach (c; 0 .. doc.columnCount)
            all[c] = cast(uint) c;
        return all;
    }();

    a.info = model.baseInfo;
    a.info.visibleRows = cast(uint) rowPerm.length;
    a.info.projected = !proj.pristine;
    a.info.windowStart = window.whole ? 0 : window.start;
    a.info.windowRows = window.rows;

    if (doc.columnCount == 0 || visCols.length == 0)
        return a; // empty input / all columns hidden: the caller degrades

    buildTable(a, doc, model.columnTypes, rowPerm, visCols,
        proj.spec.sortKeys, window);
    return a;
}

/**
`DSN3`: one width per column, measured over a bounded sample of the projected
order rather than over every record.

The sample, not the window, is what makes this stable: measuring the window
would re-fit the columns on every scroll step (the grid would breathe as a
long value scrolled in and out), and measuring all rows would put a
whole-file scan back on the path `DSN4` exists to bound. A value wider than
its sampled column wraps under the existing cap (`DSG4`) instead of widening
it — the "no reflow as later rows appear" half of `DSN3`.

Column 0 is the record-number gutter, whose width is the widest number the
view can show — known exactly from the row count, so it never shifts.
*/
private const(size_t)[] sampledColumnWidths(in DsvDoc doc,
    in uint[] visCols, in DsvInfo info) @safe
{
    // The table measures with `cellsOf` — the one width authority — so the
    // floors must be measured with it too, or a pinned column would disagree
    // with the content it is pinning.
    import sparkles.ui.geometry : cellsOf;

    auto widths = new size_t[](visCols.length + 1);
    SharedBuffer!(char, 256) cellBuf;

    size_t digits = 1;
    for (uint n = info.visibleRows; n >= 10; n /= 10)
        ++digits;
    widths[0] = digits; // the "#" header is one cell, the numbers are wider

    // The header names are always visible, so they always count.
    const first = info.hasHeader ? 1 : 0;
    if (info.hasHeader && doc.records.length)
    {
        const rec = doc.records[0];
        foreach (vi, c; visCols)
            if (c < rec.cellCount)
                widths[vi + 1] = cellsOf(
                    decodeCell(doc, doc.cells[rec.cellsStart + c], cellBuf));
    }
    else
        foreach (vi, c; visCols)
            widths[vi + 1] = cellsOf(columnName(c));

    // The sample is taken in SOURCE order, deliberately — not through the
    // projection. Sampling the projected order would make the widths a
    // function of the sort and the filter, so every sort flip and every
    // keystroke in the filter bar would re-fit the columns under the
    // reader. The geometry belongs to the FILE.
    const dataRecords = doc.records.length > first
        ? doc.records.length - first : 0;
    const sampled = dataRecords < sniffMaxRecords
        ? dataRecords : sniffMaxRecords;
    foreach (i; 0 .. sampled)
    {
        const rec = doc.records[first + i];
        foreach (vi, c; visCols)
        {
            if (c >= rec.cellCount)
                continue;
            const w = cellsOf(
                decodeCell(doc, doc.cells[rec.cellsStart + c], cellBuf));
            if (w > widths[vi + 1])
                widths[vi + 1] = w;
        }
    }

    // `DSS1`: every DATA column keeps room for a sort badge whether or not
    // it is sorted right now, so engaging a sort cannot widen it. The
    // record-number gutter never sorts and reserves nothing.
    foreach (vi; 0 .. visCols.length)
        widths[vi + 1] += dsvSortBadgeCells;

    foreach (ref w; widths)
        if (w > dsvColumnCapCells)
            w = dsvColumnCapCells;
    return widths;
}

/// Synthesizes the decoded buffer + the `table` block tree (`DSG1` via the
/// md path) over the **projected view**: header row first (real, padded with
/// `…+N` overflow names, or fully synthetic), the permuted data rows padded
/// to the grid width (`DSM3`), per-column alignment from the inferred types
/// (`DSG3`: numeric/date right, bool center). `rowPerm` holds data-record
/// indexes in view order; `visCols` the visible data columns in view order.
private void buildTable(ref DsvAdapted a, in DsvDoc doc,
    in ColumnType[] types, in uint[] rowPerm, in uint[] visCols,
    in SortKey[] sortKeys = null, in DsvWindow window = DsvWindow.init) @safe
{
    const cols = visCols.length;
    auto buf = appender!string;
    SharedBuffer!(char, 256) cellBuf;

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

    // The badge's width is RESERVED by `sampledColumnWidths`, so it
    // appearing and disappearing never moves a column.
    import sparkles.ui.geometry : cellsOf;

    // `DSS1`'s rank chrome: ` ▲`/` ▼` for a single key, `1▲`-style with
    // the rank when several sort. View-column indexed (gutter at 0).
    // A windowed grid HOLDS the badge's cells rather than collapsing them
    // (`visibility: hidden`, not `display: none`): an unsorted header pads
    // over them, so a right- or centre-aligned name — every numeric column
    // is one, `DSG3` — cannot sit flush against the edge while unsorted and
    // then jump aside the moment an arrow appears.
    const holdBadgeCells = !window.whole;
    const(char)[][] badges;
    if (sortKeys.length || holdBadgeCells)
    {
        badges = new const(char)[][](cols + 1);
        static immutable string badgePad = "  ";
        static assert(badgePad.length == dsvSortBadgeCells,
            "the placeholder must hold exactly the reserved cells");
        foreach (vi, c; visCols)
        {
            if (holdBadgeCells)
                badges[vi + 1] = badgePad;
            foreach (ki, k; sortKeys)
                if (k.column == c)
                {
                    // Both forms fit `dsvSortBadgeCells`; a rank that would
                    // not (ten keys deep) drops to the bare direction rather
                    // than overflowing the space reserved for it.
                    const arrow = k.descending ? "▼" : "▲";
                    const ranked = text(ki + 1, arrow);
                    badges[vi + 1] = sortKeys.length == 1
                        ? (k.descending ? " ▼" : " ▲")
                        : (cellsOf(ranked) <= dsvSortBadgeCells
                            ? ranked : " " ~ arrow);
                    break;
                }
        }
    }

    // `DSN3`: a windowed grid must not re-fit its columns as it scrolls, so
    // measure them once over a bounded sample of the projected order and pin
    // the result as floors. Without a window nothing is pinned — every
    // non-scrolling sink (`--html`, the goldens, copy) keeps fitting the
    // table to exactly the content it renders.
    const(size_t)[] floors;
    if (!window.whole)
        floors = sampledColumnWidths(doc, visCols, a.info);

    a.extras = MdTableExtras(
        headerCols: 1,
        columnMaxWidth: dsvColumnCapCells,
        columnWidths: floors,
        // `DSN4`: the bar describes the whole projected view and where this
        // window sits in it — the grid scrolls in view coordinates even
        // though only the window was built.
        virtualRows: window.whole ? 0 : a.info.visibleRows,
        virtualRowOffset: window.whole ? 0 : a.info.windowStart,
        columnAligns: cellAligns,
        pinHeader: true,
        // The record-number gutter stays put while the grid scrolls
        // horizontally (`DSG5` × the freeze-pane generalization).
        freezeLeftColumns: 1,
        headerBadges: badges,
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
    // `DSN4`: only the window is materialized. The projection above still
    // ran over every record — sorting and filtering are properties of the
    // whole view, not of what happens to be on screen — so this slices the
    // finished order rather than narrowing the work that produced it.
    const first = a.info.hasHeader ? 1 : 0;
    const from = window.whole ? 0 : (window.start < rowPerm.length
        ? window.start : cast(uint) rowPerm.length);
    const to = window.whole ? rowPerm.length
        : (rowPerm.length - from < window.rows ? rowPerm.length
            : from + window.rows);
    foreach (dataIdx; rowPerm[from .. to])
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
    /// View data row → data record (`DSC5`). **Borrowed** from the
    /// `DsvModel` that produced it, never copied: at the `DSN6` target this
    /// is a million entries, and duplicating it on every scroll notch would
    /// put an O(rows) memcpy — and its garbage — back on a path `DSN4` and
    /// `DSN7` exist to keep O(window). The model outlives every copy made
    /// from it, and a projection change replaces the array rather than
    /// mutating it, so a stale slice cannot be observed.
    private const(uint)[] rowPerm;
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

    /// Over a retained model (`DSN7`) — the form every scrolling caller uses.
    /// The parse, the types and the header names are the model's; only the
    /// view-coordinate maps are built here.
    static DsvCopy of(DsvModel model, in DsvInfo info,
        in DsvProjection proj = DsvProjection.init) @safe
    in (model !is null)
    {
        DsvCopy c = { rawText: model.source, info: info };
        c.projPristine = proj.pristine;
        if (!info.present || !model.usable)
            return c;

        c.parsed = model.document;
        c.parsedOk = true;
        // The same deterministic projection the adapter rendered (`DSS3` makes
        // it exact), so view coordinates map through it (`DSC5`: WYSIWYG).
        // Memoized on the model, so this is the adapter's own permutation
        // rather than a second computation of it.
        c.rowPerm = model.permutation(proj);
        c.headerNames = model.headerNames.dup;
        if (proj.columns !is null)
            c.viewCols = proj.columns.dup;
        else
        {
            c.viewCols = new uint[](c.parsed.columnCount);
            foreach (col; 0 .. c.parsed.columnCount)
                c.viewCols[col] = cast(uint) col;
        }
        return c;
    }

    /// Resolving form, for callers that hold only bytes (tests, and the
    /// one-shot sinks that never scroll).
    static DsvCopy of(string rawText, in DsvInfo info,
        in DsvProjection proj = DsvProjection.init) @safe
    {
        if (!info.present)
        {
            DsvCopy c = { rawText: rawText, info: info };
            c.projPristine = proj.pristine;
            return c;
        }
        return of(DsvModel.of(rawText, "", flagsOf(info)), info, proj);
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
            // `DSN4`: view row 1 is the WINDOW's first row, not the
            // projection's — a scrolled grid would otherwise copy the rows
            // it was showing before it moved.
            const dataRow = viewRow - 1 + info.windowStart;
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

@("dsv_view.adapt.sortRankBadges")
@system unittest
{
    import sparkles.dsv : ProjectionSpec, SortKey;

    const src = "name,qty\nb,2\na,3\n";
    DsvProjection proj = { spec: ProjectionSpec([SortKey(1, descending: true)]) };
    auto a = adaptDsv(src, "csv", DsvFlags(), proj);
    assert(a.extras.headerBadges.length == 3);
    assert(a.extras.headerBadges[2] == " ▼"); // qty, single key
    assert(a.extras.headerBadges[1] == ""); // name unbadged

    // A ranked badge drops the separating space so it fits the two cells
    // every header reserves for it (`dsvSortBadgeCells`) — the reservation
    // is what keeps a sort from widening the column.
    DsvProjection multi = { spec: ProjectionSpec([SortKey(1), SortKey(0)]) };
    a = adaptDsv(src, "csv", DsvFlags(), multi);
    assert(a.extras.headerBadges[2] == "1▲");
    assert(a.extras.headerBadges[1] == "2▲");
    // The badge renders in the grid but lives in no source buffer: the
    // header cell's model span is untouched.
    import std.algorithm.searching : canFind;

    assert(dsvGridText(a).canFind("1▲"));
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
        import sparkles.source_view.markdown : MdViewOptions, MdViewTheme,
            viewMarkdown;
        import sparkles.syntax : LabelSet, resolveTheme;
        import sparkles.ui.display_list : buildDisplayList;
        import sparkles.ui.geometry : Constraints;
        import sparkles.ui.interp.cells : CellGrid;
        import sparkles.ui.interp.immediate : paint;
        import sparkles.ui.layout : layout;
        import sparkles.ui.style : defaultTwoslashPalette;
        import sparkles.ui.themes : builtinThemes;

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

@("dsv_view.window.materializesOnlyTheSlice")
@safe
unittest
{
    import std.algorithm : canFind;

    auto src = "n,name\n";
    foreach (i; 0 .. 500)
        src ~= text(i, ",row", i, "\n");

    // The whole view is the default, and stays the shape every non-scrolling
    // sink gets: one table row per data record (plus the header).
    const all = adaptDsv(src, "csv", DsvFlags());
    assert(all.info.visibleRows == 500);
    assert(all.info.windowRows == 0 && all.info.materializedRows == 500);
    assert(all.doc.root.children[0].children.length == 501);
    assert(all.extras.columnWidths.length == 0, "unwindowed: nothing pinned");

    // A window materializes its slice only — while `visibleRows` keeps
    // reporting the virtual total the scrollbar and the chrome need.
    const win = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init,
        DsvWindow(start: 100, rows: 40));
    assert(win.info.visibleRows == 500, "the view is still 500 rows long");
    assert(win.info.materializedRows == 40);
    assert(win.doc.root.children[0].children.length == 41); // header + 40
    // Gutter numbers are 1-based SOURCE order (`DSG5`), so the window's
    // first row proves WHICH rows were materialized.
    assert(win.text.canFind("\n101,"), "the window starts at row 101");
    assert(!win.text.canFind("\n100,"), "and not before it");

    // A window running past the end clamps instead of over-reading.
    const tail = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init,
        DsvWindow(start: 480, rows: 40));
    assert(tail.info.materializedRows == 20);
    assert(tail.doc.root.children[0].children.length == 21);

    // Past the end entirely: the header alone, no crash.
    const past = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init,
        DsvWindow(start: 900, rows: 40));
    assert(past.info.materializedRows == 0);
    assert(past.doc.root.children[0].children.length == 1);
}

@("dsv_view.window.renderedGeometryIsIdenticalAcrossWindows")
@system
unittest
{
    import std.algorithm : canFind, map, maxElement;
    import std.string : splitLines;

    // `DSN3`: the reader must not see the table resize under them as they
    // scroll. A floor alone does not deliver that — a row wider than the
    // sample still widens its column — so the widths are pinned on BOTH
    // sides and the rendered frame must come out the same width everywhere
    // in the view, including over a row far wider than anything sampled.
    auto src = "id,note\n";
    foreach (i; 0 .. 400)
        src ~= text(i, ",",
            i == 350 ? "a-value-far-wider-than-any-in-the-sample" : "x", "\n");

    size_t widthOf(uint start)
    {
        const a = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init,
            DsvWindow(start: start, rows: 12));
        return dsvGridText(a, 14).splitLines
            .map!(l => l.length).maxElement;
    }

    const head = widthOf(0);
    const overWide = widthOf(345); // the wide row is inside this window
    const tail = widthOf(380);
    assert(head == overWide && head == tail,
        "the grid keeps one geometry however wide the rows in view are");
}

@("dsv_view.window.badgeSpaceIsHeldNotCollapsed")
@system unittest
{
    import std.algorithm.searching : canFind, countUntil;
    import std.string : splitLines;

    // The reserved space must behave like `visibility: hidden`, not
    // `display: none`: an unsorted header PADS over the badge's cells
    // instead of spreading into them. Otherwise a right-aligned header —
    // every numeric column is one (`DSG3`) — sits flush right while
    // unsorted and jumps two cells left the moment an arrow appears.
    auto src = "qty,name\n";
    foreach (i; 0 .. 40)
        src ~= text(i, ",row", i, "\n");

    ptrdiff_t headerAt(in DsvProjection proj)
    {
        const a = adaptDsv(src, "csv", DsvFlags(), proj,
            DsvWindow(start: 0, rows: 10));
        foreach (line; dsvGridText(a, 12).splitLines)
            if (line.canFind("qty"))
                return line.countUntil("qty");
        return -1;
    }

    const unsorted = headerAt(DsvProjection.init);
    assert(unsorted >= 0, "precondition: the header renders");

    DsvProjection sorted;
    sorted.spec.sortKeys = [SortKey(column: 0, descending: false)];
    assert(headerAt(sorted) == unsorted,
        "the column name must not move when its arrow appears");
}

@("dsv_view.window.reservedBadgeStaysLegible")
@system unittest
{
    import std.algorithm.searching : canFind;

    // The reservation is not only about width. A windowed grid pins each
    // column to one width, so a badge with no room reserved for it is not
    // merely tight — the pin CLIPS it, and the reader sorts a column and
    // sees no arrow at all. `dsvSortBadgeCells` is what keeps the chrome
    // legible without letting it move the column.
    auto src = "n,a-rather-wide-header-name\n";
    foreach (i; 0 .. 20)
        src ~= text(i, ",x\n");

    DsvProjection sorted;
    sorted.spec.sortKeys = [SortKey(column: 1, descending: false)];
    const win = adaptDsv(src, "csv", DsvFlags(), sorted,
        DsvWindow(start: 0, rows: 8));
    assert(dsvGridText(win, 10).canFind("▲"),
        "a sorted column must show its direction inside its pinned width");
}

// `DSN7`: the retained model. A scroll must be a QUERY against it — same
// answers as the resolving path, without re-deriving anything.

@("dsv_view.model.windowsAgreeWithTheResolvingPath")
@safe
unittest
{
    auto src = "n,name\n";
    foreach (i; 0 .. 300)
        src ~= text(i, ",row", i, "\n");

    auto model = DsvModel.of(src, "csv", DsvFlags());
    assert(model.usable);

    // Every window built from the retained model must be byte-identical to
    // the one the one-shot path produces — the model is an optimization, not
    // a different renderer.
    foreach (start; [0u, 37u, 260u, 299u, 400u])
    {
        const win = DsvWindow(start: start, rows: 25);
        const viaModel = adaptDsv(model, DsvProjection.init, win);
        const viaBytes = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init, win);
        assert(viaModel.text == viaBytes.text,
            "a windowed query must render exactly what re-deriving renders");
        assert(viaModel.info.visibleRows == viaBytes.info.visibleRows);
        assert(viaModel.info.windowStart == viaBytes.info.windowStart);
        assert(viaModel.extras.columnWidths == viaBytes.extras.columnWidths,
            "and pin the same geometry");
    }
}

@("dsv_view.model.memoizesTheProjection")
@safe
unittest
{
    auto src = "n,name\n";
    foreach (i; 0 .. 200)
        src ~= text(i, ",row", 199 - i, "\n");

    auto model = DsvModel.of(src, "csv", DsvFlags());

    // The same projection must hand back the SAME array, not an equal one:
    // identity is the proof that the sort did not run again. This is the
    // whole point — a sorted 3 k-row file was re-sorting on every notch.
    DsvProjection sorted;
    sorted.spec = ProjectionSpec(sortKeys: [SortKey(column: 1)]);
    const first = model.permutation(sorted);
    const again = model.permutation(sorted);
    assert(first.ptr is again.ptr && first.length == again.length,
        "an unchanged projection must not recompute the permutation");
    assert(first.length == 200);

    // A projection that is EQUAL but freshly built still hits: the memo is
    // keyed by value, so the caller may rebuild its spec every frame (which
    // `DsvBrowser.projection` does).
    DsvProjection rebuilt;
    rebuilt.spec = ProjectionSpec(sortKeys: [SortKey(column: 1)]);
    assert(model.permutation(rebuilt).ptr is first.ptr,
        "an equal projection is the same projection");

    // A different one must miss, and be right.
    DsvProjection desc;
    desc.spec = ProjectionSpec(sortKeys: [SortKey(column: 1, descending: true)]);
    const flipped = model.permutation(desc);
    assert(flipped.ptr !is first.ptr, "a changed sort must recompute");
    assert(flipped[0] != first[0], "and must actually reverse the order");

    // Going back re-computes rather than resurrecting a stale answer — the
    // memo holds one entry, and must never hand back the wrong one.
    assert(model.permutation(sorted) == first);
}

@("dsv_view.model.reresolvesWhenTheDocumentChanges")
@safe
unittest
{
    const a = "n,name\n1,alice\n2,bob\n";
    auto model = DsvModel.of(a, "csv", DsvFlags());
    assert(model.describes(a, DsvFlags()));

    // A reload produces a different buffer. Equal CONTENT is not the same
    // document: the model borrows the bytes, so identity is the test.
    const sameContent = "n,name\n1,alice\n2,bob\n".idup;
    assert(!model.describes(sameContent, DsvFlags()),
        "a fresh buffer must re-resolve even when the bytes match");
    assert(modelFor(model, sameContent, "csv", DsvFlags()) !is model);
    assert(modelFor(model, a, "csv", DsvFlags()) is model,
        "the same bytes and flags reuse the model");

    // A flag override changes the grid, so it must re-resolve too.
    assert(!model.describes(a, DsvFlags(delimiter: ";")));
    assert(modelFor(model, a, "csv", DsvFlags(delimiter: ";")) !is model);
}

@("dsv_view.model.rowMaskMemoFollowsTheParts")
@safe
unittest
{
    const src = "n,name\n1,alice\n2,bob\n";
    auto model = DsvModel.of(src, "csv", DsvFlags());

    assert(!model.hasCachedRowMask(["alice"]));
    auto mask = [true, false];
    assert(model.cacheRowMask(["alice"], mask) is mask);
    assert(model.hasCachedRowMask(["alice"]));
    assert(model.cachedRowMask(["alice"]) is mask);

    // Keyed by CONTENT: the parts are rebuilt from the filter text on every
    // keystroke, so an identity key would never hit.
    assert(model.hasCachedRowMask(["alice".idup]));
    assert(!model.hasCachedRowMask(["bob"]));
    assert(model.cachedRowMask(["bob"]) is null);

    // A null memo is a memo: an unparseable query legitimately yields none,
    // and must not be recomputed on every frame.
    model.cacheRowMask(["("], null);
    assert(model.hasCachedRowMask(["("]));
    assert(model.cachedRowMask(["("]) is null);
}

@("dsv_view.model.copyReadsTheSameCellsAsTheResolvingPath")
@safe
unittest
{
    auto src = "n,name\n";
    foreach (i; 0 .. 120)
        src ~= text(i, ",row", i, "\n");

    DsvProjection sorted;
    sorted.spec = ProjectionSpec(sortKeys: [SortKey(column: 1, descending: true)]);

    auto model = DsvModel.of(src, "csv", DsvFlags());
    const win = adaptDsv(model, sorted, DsvWindow(start: 30, rows: 20));
    const viaModel = DsvCopy.of(model, win.info, sorted);
    const viaBytes = DsvCopy.of(src, win.info, sorted);

    // `DSC5`: copy maps view coordinates through the projection AND the
    // window. Sharing the model's memoized permutation must not change which
    // record a view cell names.
    foreach (row; 0 .. 21)
        foreach (col; 0 .. 3)
            assert(viaModel.rawCell(row, col) == viaBytes.rawCell(row, col),
                "the model-backed copy must name the same cells");
}

@("dsv_view.window.sortAndFilterKeepTheGeometry")
@system
unittest
{
    import std.algorithm : map, maxElement;
    import std.string : splitLines;

    // The grid must not resize when the reader sorts or filters it. Two
    // separate ways it used to: the sort BADGE is extra header content, and
    // the pinned widths were sampled from the PROJECTED order — so changing
    // that order changed which rows the sample saw, and with them the
    // widths.
    auto src = "id,note\n";
    foreach (i; 0 .. 300)
        src ~= text(i, ",", i % 7 == 0 ? "a-much-longer-value-here" : "x", "\n");

    size_t[2] geometryOf(in DsvProjection proj)
    {
        const a = adaptDsv(src, "csv", DsvFlags(), proj,
            DsvWindow(start: 0, rows: 12));
        const lines = dsvGridText(a, 14).splitLines;
        return [lines.map!(l => l.length).maxElement, lines.length];
    }

    const plain = geometryOf(DsvProjection.init);

    // Sorting: the badge appears in a header cell.
    DsvProjection sorted;
    sorted.spec.sortKeys = [SortKey(column: 1, descending: false)];
    assert(geometryOf(sorted) == plain,
        "a sort badge must not resize the grid");

    // And descending, which is a different glyph.
    DsvProjection desc;
    desc.spec.sortKeys = [SortKey(column: 1, descending: true)];
    assert(geometryOf(desc) == plain);

    // The badge's own case needs a column whose HEADER is the widest thing
    // in it — otherwise the data decides the width and the badge fits in
    // the slack by luck. `dsvSortBadgeCells` is what makes this hold.
    auto narrow = "n,a-rather-wide-header-name\n";
    foreach (i; 0 .. 60)
        narrow ~= text(i, ",x\n");

    size_t[2] narrowGeometry(in DsvProjection proj)
    {
        const a = adaptDsv(narrow, "csv", DsvFlags(), proj,
            DsvWindow(start: 0, rows: 10));
        const lines = dsvGridText(a, 12).splitLines;
        return [lines.map!(l => l.length).maxElement, lines.length];
    }

    const narrowPlain = narrowGeometry(DsvProjection.init);
    DsvProjection narrowSorted;
    narrowSorted.spec.sortKeys = [SortKey(column: 1, descending: false)];
    assert(narrowGeometry(narrowSorted) == narrowPlain,
        "a header-dominated column keeps its width when sorted");

    // Filtering: a different row set, so a different sample.
    auto mask = new bool[](300);
    foreach (i; 0 .. 300)
        mask[i] = i % 7 != 0; // drops every long value
    DsvProjection filtered;
    filtered.rowMask = mask;
    assert(geometryOf(filtered) == plain,
        "a filter must not resize the grid either");
}

@("dsv_view.window.copyFollowsTheWindow")
@safe
unittest
{
    // `DSC5` × `DSN4`: the copy is what the view SHOWS. Once the grid is a
    // window, view row 1 is the window's first row — a `source` copy that
    // still mapped it through the head of the projection would hand back
    // rows the reader scrolled past.
    auto src = "id,name\n";
    foreach (i; 0 .. 200)
        src ~= text(i, ",name", i, "\n");

    const win = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init,
        DsvWindow(start: 50, rows: 10));
    const copy = DsvCopy.of(src, win.info);
    assert(copy.present);
    assert(copy.rawCell(0, 2) == "name", "the header is the header");
    assert(copy.rawCell(1, 2) == "name50", "view row 1 IS the window's first");
    assert(copy.rawCell(2, 2) == "name51");

    // The unwindowed view is unchanged: row 1 is the projection's first.
    const all = adaptDsv(src, "csv", DsvFlags());
    const copyAll = DsvCopy.of(src, all.info);
    assert(copyAll.rawCell(1, 2) == "name0");
}

@("dsv_view.window.geometryDoesNotJitterAsItScrolls")
@safe
unittest
{
    // `DSN3`: the column that holds a long value only in the tail must be
    // just as wide in a window that cannot see it — otherwise the grid
    // breathes as the reader scrolls, which is what pinning prevents.
    auto src = "id,note\n";
    foreach (i; 0 .. 400)
        src ~= text(i, ",", i == 399 ? "a-very-long-trailing-value" : "x", "\n");

    const head = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init,
        DsvWindow(start: 0, rows: 20));
    const tail = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init,
        DsvWindow(start: 380, rows: 20));
    assert(head.extras.columnWidths.length == 3); // gutter + 2 columns
    assert(head.extras.columnWidths == tail.extras.columnWidths,
        "the pinned widths are a property of the view, not of the window");

    // The gutter is pinned to the widest record number the view can show,
    // so it does not widen when the reader reaches row 100 or 400.
    assert(head.extras.columnWidths[0] == 3);
}

@("dsv_view.window.rendersFromItsFirstRow")
@system
unittest
{
    import std.algorithm : canFind;

    // `DSN4`: the window IS the scroll. A host that moves the window and
    // ALSO hands the table its scroll offset scrolls twice — the window's
    // own head is skipped and its tail runs off the viewport, which is how
    // the grid stopped answering hit tests after one wheel notch.
    auto src = "id,name\n";
    foreach (i; 0 .. 300)
        src ~= text(i, ",name", i, "\n");

    const win = adaptDsv(src, "csv", DsvFlags(), DsvProjection.init,
        DsvWindow(start: 100, rows: 20));
    // Rendered the way hue renders it: a viewport shorter than the window,
    // with the host's scroll offset carried alongside — the shape that used
    // to double-scroll.
    const shown = dsvGridText(win, 12, 0, 100);
    assert(shown.canFind("name100"),
        "the window's first row must be at the top of the grid");
    assert(!shown.canFind("name120"), "and its tail stays past the viewport");
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
