// Presentation-free 2D table selection logic for `hue --gui` (spec `TBL1`/`TBL2`/
// `TBL5`): resolve a smart drag (+ Shift/Alt) into a `TableRegion`, and serialize
// a region to clipboard text. No raylib — pure over `GridHit`s (from the
// `sparkles:core-cli` table map) and a cell-text accessor, so it is unit-testable.
module table_select;

import sparkles.core_cli.ui.table : GridHit;

/// How a table grid selection serializes to the clipboard (`CLI11`/`TBL2`).
enum TableCopyFormat : ubyte
{
    tsv,      /// rows as lines, cells tab-separated (spreadsheet-friendly)
    markdown, /// re-emitted `| … |` rows (first selected row as header)
}

/// A resolved table selection: either a **sub-cell** byte range within one cell,
/// or a **rectangle** of whole cells (inclusive bounds).
struct TableRegion
{
    bool subCell;
    // sub-cell: the cell and a `[charLo, charHi)` byte range into its content.
    size_t row, col, charLo, charHi;
    // rectangle: inclusive grid bounds.
    size_t rowLo, rowHi, colLo, colHi;
}

/**
Resolve a drag from `anchor` to `head` (both cells from the table map) under the
Shift/Alt modifiers into a $(LREF TableRegion) (`TBL1`):

$(UL
$(LI same cell and no modifier → a **sub-cell** character range;)
$(LI otherwise a **rectangle** spanning both cells, with **Shift** snapping to
    full rows (all columns) and **Alt** to full columns (all rows).))
*/
TableRegion tableSelection(GridHit anchor, GridHit head, bool shift, bool alt,
    size_t numRows, size_t numCols) @safe pure nothrow @nogc
{
    static size_t lo(size_t a, size_t b) => a < b ? a : b;
    static size_t hi(size_t a, size_t b) => a < b ? b : a;

    TableRegion r;
    if (!shift && !alt && anchor.row == head.row && anchor.col == head.col)
    {
        r.subCell = true;
        r.row = anchor.row;
        r.col = anchor.col;
        r.charLo = lo(anchor.charInCell, head.charInCell);
        r.charHi = hi(anchor.charInCell, head.charInCell);
        return r;
    }

    r.rowLo = lo(anchor.row, head.row);
    r.rowHi = hi(anchor.row, head.row);
    r.colLo = lo(anchor.col, head.col);
    r.colHi = hi(anchor.col, head.col);
    if (shift) { r.colLo = 0; r.colHi = numCols ? numCols - 1 : 0; }
    if (alt)   { r.rowLo = 0; r.rowHi = numRows ? numRows - 1 : 0; }
    return r;
}

/**
Serialize `reg` to clipboard text via a `cell(row, col)` content accessor, per
`fmt` (`TBL2`): a sub-cell → the cell substring; a rectangle → cells joined by
`\t`/`\n` (`tsv`) or re-emitted as a `| … |` markdown table (`markdown`, with a
`| --- |` delimiter after the first selected row so the copy is a valid table).
*/
string serializeTable(in TableRegion reg,
    scope const(char)[] delegate(size_t, size_t) @safe cell, TableCopyFormat fmt) @safe
{
    import std.array : appender;

    if (reg.subCell)
    {
        const t = cell(reg.row, reg.col);
        const a = reg.charLo > t.length ? t.length : reg.charLo;
        const b = reg.charHi > t.length ? t.length : reg.charHi;
        return t[a .. b].idup;
    }

    const cols = reg.colHi - reg.colLo + 1;
    auto w = appender!string;

    // Emit one line of `cols` cells, taking each from `at(i)` (0-based within the
    // selected column range).
    void line(scope const(char)[] delegate(size_t) @safe at)
    {
        foreach (i; 0 .. cols)
        {
            if (fmt == TableCopyFormat.markdown)
                w ~= i == 0 ? "| " : " | ";
            else if (i)
                w ~= '\t';
            w ~= at(i);
        }
        if (fmt == TableCopyFormat.markdown)
            w ~= " |";
    }

    bool first = true;
    foreach (r; reg.rowLo .. reg.rowHi + 1)
    {
        if (!first)
            w ~= '\n';
        line(i => cell(r, reg.colLo + i));
        if (fmt == TableCopyFormat.markdown && first)
        {
            w ~= '\n';
            line(_ => "---"); // the header delimiter row
        }
        first = false;
    }
    return w[];
}

// ── tests ─────────────────────────────────────────────────────────────────────

version (unittest)
{
    // A 3×3 stub grid `r,c` → "rXcY".
    private const(char)[] stubCell(size_t r, size_t c) @safe
    {
        static immutable string[3][3] g = [
            ["Name", "Age", "City"],
            ["Ann", "30", "Rome"],
            ["Bo", "9", "Oslo"],
        ];
        return g[r][c];
    }

    private GridHit at(size_t r, size_t c, size_t ch = 0) @safe pure nothrow @nogc
        => GridHit(r, c, ch);
}

@("table_select.region.subCell")
@safe unittest
{
    // Same cell, no modifier → a sub-cell char range (ordered).
    const r = tableSelection(at(1, 0, 3), at(1, 0, 1), false, false, 3, 3);
    assert(r.subCell && r.row == 1 && r.col == 0 && r.charLo == 1 && r.charHi == 3);
}

@("table_select.region.rectangle")
@safe unittest
{
    // Cross-cell drag → an ordered rectangle regardless of drag direction.
    const r = tableSelection(at(2, 2), at(0, 1), false, false, 3, 3);
    assert(!r.subCell && r.rowLo == 0 && r.rowHi == 2 && r.colLo == 1 && r.colHi == 2);
}

@("table_select.region.modifiers")
@safe unittest
{
    // Shift → full rows (all columns); Alt → full columns (all rows).
    const rows = tableSelection(at(1, 1), at(1, 1), true, false, 3, 3);
    assert(!rows.subCell && rows.rowLo == 1 && rows.rowHi == 1 && rows.colLo == 0 && rows.colHi == 2);

    const colsSel = tableSelection(at(0, 2), at(2, 2), false, true, 3, 3);
    assert(colsSel.rowLo == 0 && colsSel.rowHi == 2 && colsSel.colLo == 2 && colsSel.colHi == 2);
}

@("table_select.serialize.tsv")
@safe unittest
{
    const r = tableSelection(at(0, 0), at(1, 1), false, false, 3, 3);
    assert(serializeTable(r, (size_t r, size_t c) => stubCell(r, c), TableCopyFormat.tsv)
        == "Name\tAge\nAnn\t30");
}

@("table_select.serialize.markdown")
@safe unittest
{
    const r = tableSelection(at(0, 0), at(1, 1), false, false, 3, 3);
    assert(serializeTable(r, (size_t r, size_t c) => stubCell(r, c), TableCopyFormat.markdown)
        == "| Name | Age |\n| --- | --- |\n| Ann | 30 |");
}

@("table_select.serialize.subCell")
@safe unittest
{
    // "Name"[1..3] == "am"; out-of-range hi clamps to the cell length.
    const r = TableRegion(subCell: true, row: 0, col: 0, charLo: 1, charHi: 3);
    assert(serializeTable(r, (size_t r, size_t c) => stubCell(r, c), TableCopyFormat.tsv) == "am");
    const r2 = TableRegion(subCell: true, row: 0, col: 0, charLo: 0, charHi: 99);
    assert(serializeTable(r2, (size_t r, size_t c) => stubCell(r, c), TableCopyFormat.tsv) == "Name");
}
