/++
Pure table-model resolution — the "forming a table" half of the span-capable
table (see `docs/specs/core-cli/table.md` §2–3): the authoring forms
(dense `Cell[][]`, sparse `Placement[]`, `string[][]` sugar), the HTML
slot-grid placement algorithm, and validation. No rendering concern lives
here (nothing in this module touches `TableProps`); the renderer is
`sparkles.core_cli.ui.table.render`, and both are re-exported through the
`sparkles.core_cli.ui.table` package module.
+/
module sparkles.core_cli.ui.table.grid;

import std.algorithm : all, map, maxElement;
import std.algorithm.comparison : max;
import std.array : array;
import std.range : iota;

import expected : Expected, err, ok;

import sparkles.base.text.grapheme : visibleWidth;

bool hasRectangularShape(T)(const T[][] array)
{
    size_t width = array[0].length;
    return array.all!(row => row.length == width);
}

unittest
{
    assert([[]].hasRectangularShape());
    assert([[1]].hasRectangularShape());
    assert([[], []].hasRectangularShape());
    assert([[1], [2]].hasRectangularShape());
    assert([[], [], []].hasRectangularShape());
    assert([[1], [2], [3]].hasRectangularShape());
    assert([[1, 2], [3, 4], [5, 6]].hasRectangularShape());
    assert([[1, 2, 3], [4, 5, 6], [7, 8, 9]].hasRectangularShape());

    assert(![[], [1], [1, 2]].hasRectangularShape());
    assert(![[1, 2], [1], [1, 2]].hasRectangularShape());
    assert(![[1], [2], [3, 3], []].hasRectangularShape());
    assert(![[1, 2], [3, 4], []].hasRectangularShape());
}

size_t[] columnWidths(string[][] cells)
in (hasRectangularShape(cells))
{
    return cells[0].length
        .iota
        .map!(col => cells.map!(row => visibleWidth(row[col])).maxElement())
        .array;
}

unittest
{
    assert(columnWidths([[""]]) == [0]);
    assert(columnWidths([
        ["1", "123"],
        ["12", ""]
    ]) == [2, 3]);
    assert(columnWidths([
        ["1234", "1"],
        ["1", ""],
        ["123", "12345"],
        ["", "12"]
    ]) == [4, 5]);
}
/// One content object anchored at `(row, col)` covering a `rowSpan × colSpan`
/// rectangle of slots. `implicit` marks a filler synthesized for a slot no authored
/// cell covers (keeps the grid fully populated).
package(sparkles.core_cli.ui.table) struct Anchor
{
    size_t row, col, rowSpan, colSpan;
    string content;
    bool implicit;
}

/// The resolved grid: dimensions, the anchor list, and a slot→anchor map so
/// `owner(r, c)` is O(1). Coverage is derived from this, never stored per anchor.
package(sparkles.core_cli.ui.table) struct SlotGrid
{
    size_t numRows, numCols;
    Anchor[] anchors;
    size_t[] slotOwner; // [r*numCols + c] -> index into anchors
}

/// A table cell for the dense authoring form `Cell[][]`. `colSpan`/`rowSpan` (default
/// 1) make it cover a rectangle of grid slots; the slots it covers are **omitted**
/// from the following cells of this and later rows (the placement cursor skips them).
/// A plain `string[][]` is sugar for extent-1 cells.
struct Cell
{
    string content;    /// Cell text (may contain `\n`; wraps to the column width).
    size_t colSpan = 1;/// Number of columns this cell spans.
    size_t rowSpan = 1;/// Number of rows this cell spans.
}

/// A cell for the sparse authoring form `Placement[]`: it names its own `(row, col)`
/// and extent, so placements are order-independent and never need filler for the gaps
/// (uncovered slots become implicit blanks). Equivalent in power to `Cell[][]`.
struct Placement
{
    size_t row;        /// Anchor row (0-based).
    size_t col;        /// Anchor column (0-based).
    string content;    /// Cell text (may contain `\n`; wraps to the column width).
    size_t colSpan = 1;/// Number of columns this cell spans.
    size_t rowSpan = 1;/// Number of rows this cell spans.
}

/// What kind of table-model error `validateTable` found.
enum TableErrorKind
{
    overlap,            /// Two cells cover the same slot.
    rowSpanOutOfBounds, /// A rowspan extended past the last authored row (clamped).
}

/// A table-model error. `drawTable` renders a malformed table deterministically anyway
/// (first-writer-wins on overlap, rowspans clamped); `validateTable` surfaces these for
/// callers that want to reject one. `row`/`col` locate the offending slot or anchor.
struct TableError
{
    TableErrorKind kind;
    size_t row;
    size_t col;
    string message;
}

/// A resolved grid together with any table-model errors found while placing it.
package(sparkles.core_cli.ui.table) struct Resolved
{
    SlotGrid grid;
    TableError[] errors;
}

package(sparkles.core_cli.ui.table) Cell[][] toCells(in string[][] rows) @safe pure nothrow
{
    auto out_ = new Cell[][](rows.length);
    foreach (r, row; rows)
    {
        out_[r] = new Cell[](row.length);
        foreach (c, s; row)
            out_[r][c] = Cell(s);
    }
    return out_;
}

/// Place cells on the grid with the HTML "forming a table" cursor: walk row-major,
/// skip already-covered slots, claim each anchor's rectangle (first-writer-wins),
/// clamp rowspans past the last authored row, then fill every uncovered slot with an
/// implicit empty anchor so the grid is fully populated (always renderable). Overlaps
/// and clamped rowspans are recorded as `TableError`s.
package(sparkles.core_cli.ui.table) Resolved resolveGrid(in Cell[][] rows) @safe pure nothrow
{
    Anchor[] anchors;
    TableError[] errors;
    bool[][] occ;
    size_t[][] owner; // anchor index + 1; 0 == empty
    occ.length = rows.length;
    owner.length = rows.length;
    size_t numCols;

    void ensure(size_t r, size_t c) @safe pure nothrow
    {
        if (r >= occ.length)
        {
            occ.length = r + 1;
            owner.length = r + 1;
        }
        if (c >= occ[r].length)
        {
            occ[r].length = c + 1;
            owner[r].length = c + 1;
        }
    }

    const numRows = rows.length;
    foreach (r, row; rows)
    {
        size_t c = 0;
        foreach (cell; row)
        {
            for (;;) // advance past slots an earlier anchor already covers
            {
                ensure(r, c);
                if (occ[r][c])
                    c++;
                else
                    break;
            }
            const cs = cell.colSpan < 1 ? 1 : cell.colSpan;
            const rs = cell.rowSpan < 1 ? 1 : cell.rowSpan;
            const idx = anchors.length;
            anchors ~= Anchor(r, c, rs, cs, cell.content, false);
            if (r + rs > numRows)
                errors ~= TableError(TableErrorKind.rowSpanOutOfBounds, r, c,
                    "rowspan extends past the last row");
            foreach (dr; 0 .. rs)
                foreach (dc; 0 .. cs)
                {
                    ensure(r + dr, c + dc);
                    if (occ[r + dr][c + dc]) // first-writer-wins; record the collision
                        errors ~= TableError(TableErrorKind.overlap, r + dr, c + dc,
                            "cell overlaps another");
                    else
                    {
                        occ[r + dr][c + dc] = true;
                        owner[r + dr][c + dc] = idx + 1;
                    }
                }
            numCols = max(numCols, c + cs);
            c += cs;
        }
    }

    return Resolved(finalizeGrid(anchors, occ, owner, numRows, numCols), errors);
}

/// The sparse authoring form: each `Placement` claims its rectangle at its own
/// `(row, col)` (no cursor). Same first-writer-wins overlap handling, rowspan clamp,
/// and implicit sparse-fill as the dense path, producing an identical `SlotGrid` — so
/// both feed the one renderer. Grid dimensions are inferred from the max extents used.
package(sparkles.core_cli.ui.table) Resolved resolveGrid(in Placement[] placements) @safe pure nothrow
{
    Anchor[] anchors;
    TableError[] errors;
    bool[][] occ;
    size_t[][] owner; // anchor index + 1; 0 == empty
    size_t numRows, numCols;

    void ensure(size_t r, size_t c) @safe pure nothrow
    {
        if (r >= occ.length)
        {
            occ.length = r + 1;
            owner.length = r + 1;
        }
        if (c >= occ[r].length)
        {
            occ[r].length = c + 1;
            owner[r].length = c + 1;
        }
    }

    foreach (pl; placements)
    {
        const cs = pl.colSpan < 1 ? 1 : pl.colSpan;
        const rs = pl.rowSpan < 1 ? 1 : pl.rowSpan;
        const idx = anchors.length;
        anchors ~= Anchor(pl.row, pl.col, rs, cs, pl.content, false);
        foreach (dr; 0 .. rs)
            foreach (dc; 0 .. cs)
            {
                ensure(pl.row + dr, pl.col + dc);
                if (occ[pl.row + dr][pl.col + dc]) // first-writer-wins; record collision
                    errors ~= TableError(TableErrorKind.overlap, pl.row + dr, pl.col + dc,
                        "cell overlaps another");
                else
                {
                    occ[pl.row + dr][pl.col + dc] = true;
                    owner[pl.row + dr][pl.col + dc] = idx + 1;
                }
            }
        numRows = max(numRows, pl.row + rs);
        numCols = max(numCols, pl.col + cs);
    }

    return Resolved(finalizeGrid(anchors, occ, owner, max(numRows, occ.length), numCols), errors);
}

/// Clamp any rowspan past the last row, fill every uncovered slot with an implicit
/// empty anchor, and build the slot→anchor map. Shared by both `resolveGrid` overloads
/// so dense and sparse inputs produce the same fully-populated (always renderable) grid.
package(sparkles.core_cli.ui.table) SlotGrid finalizeGrid(Anchor[] anchors, bool[][] occ, size_t[][] owner,
    size_t numRows, size_t numCols) @safe pure nothrow
{
    foreach (ref a; anchors)
        if (a.row + a.rowSpan > numRows)
            a.rowSpan = numRows - a.row;

    auto slotOwner = new size_t[numRows * numCols];
    foreach (r; 0 .. numRows)
        foreach (c; 0 .. numCols)
        {
            const o = (r < owner.length && c < owner[r].length) ? owner[r][c] : 0;
            if (o == 0)
            {
                slotOwner[r * numCols + c] = anchors.length;
                anchors ~= Anchor(r, c, 1, 1, "", true);
            }
            else
                slotOwner[r * numCols + c] = o - 1;
        }

    return SlotGrid(numRows, numCols, anchors, slotOwner);
}

package(sparkles.core_cli.ui.table) size_t owner(in SlotGrid g, size_t r, size_t c) @safe pure nothrow @nogc
    => g.slotOwner[r * g.numCols + c];

/// Validate a table's cell placement, returning the first table-model error (overlap
/// or an over-long rowspan) or `true` when the table is well-formed. `drawTable`
/// renders either way; call this first when a malformed table should be rejected.
/// Works with the dense `Cell[][]` or sparse `Placement[]` form.
Expected!(bool, TableError) validateTable(T)(in T[] cells)
if (is(T == Cell[]) || is(T == Placement))
{
    auto r = resolveGrid(cells);
    return r.errors.length ? err!bool(r.errors[0]) : ok!TableError(true);
}

/// Every table-model error in placement order (empty = well-formed) — the
/// all-errors sibling of `validateTable`, for callers that report rather than
/// merely reject.
TableError[] validateTableAll(T)(in T[] cells)
if (is(T == Cell[]) || is(T == Placement))
{
    return resolveGrid(cells).errors;
}
