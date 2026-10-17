/++
A table built in place. Every cell's text is written into one buffer the
builder owns, and the cell keeps its place in it, so a cell formatted from a
value (`cell!writeDuration(d)`, or `duration(d)` in a `row`)
costs no `string` of its own.

The layout must measure every cell before it emits a line, so cell text has
to exist before rendering; this is where it lives. `cells` snapshots the builder
as an owned dense cell view, and
`drawTable(w, builder, props)` does that for you.
+/
module sparkles.ui.components.table.builder;

import sparkles.base.buffer : HeapBuffer, Storage, UniqueBuffer;
import sparkles.base.text.width : Align;
import sparkles.ui.components.table.grid : Cell, VAlign;

/// See the module documentation.
struct TableBuilder
{
    private static struct Pending
    {
        size_t start, end;
        size_t colSpan = 1, rowSpan = 1;
        Align halign = Align.inherit;
        VAlign valign = VAlign.inherit;
    }

    private UniqueBuffer!char _text;
    private UniqueBuffer!Pending _pending;
    private UniqueBuffer!size_t _rows;

    /// Copies the builder's owned text and cell offsets for value-form writers.
    this(ref scope const TableBuilder other) @safe pure nothrow @nogc
    {
        _text.put(other._text[]);
        _pending.put(other._pending[]);
        _rows.put(other._rows[]);
    }

    /// Starts a new, empty row; the cells added next go in it.
    ref TableBuilder row() return @safe pure nothrow @nogc
    {
        _rows.put(_pending.length);
        return this;
    }

    /**
    Appends a row with one cell per value. A string is copied; anything else
    is written in place as `writeValue` (`sparkles.base.text.writers`) renders
    it: numbers, enums, and values that write themselves through
    `toString(Writer)` such as `duration(d)`.
    */
    ref TableBuilder row(Values...)(auto ref Values values) return
    if (Values.length > 0)
    {
        import sparkles.base.text.writers : writeValue;

        row();
        static foreach (i; 0 .. Values.length)
            add((ref UniqueBuffer!char w) => writeValue(w, values[i]));
        return this;
    }

    /// Appends a cell holding `text` to the current row.
    ref TableBuilder cell(scope const(char)[] text) return @safe pure nothrow @nogc
        => add((ref UniqueBuffer!char w) => w.put(text));

    /// Appends a cell holding what `write(w, args)` writes, written in place.
    ref TableBuilder cell(alias write, Args...)(auto ref Args args) return
        => add((ref UniqueBuffer!char w) => write(w, args));

    /// Makes the last cell span `cols` columns and `rows` rows (see `Cell`).
    ref TableBuilder span(size_t cols, size_t rows = 1) return
        @safe pure nothrow @nogc
    in (lastCell !is null, "span: no cell to span")
    {
        lastCell.colSpan = cols;
        lastCell.rowSpan = rows;
        return this;
    }

    /// Overrides the last cell's alignment (see `Cell`).
    ref TableBuilder aligned(Align h, VAlign v = VAlign.inherit) return
        @safe pure nothrow @nogc
    in (lastCell !is null, "aligned: no cell to align")
    {
        lastCell.halign = h;
        lastCell.valign = v;
        return this;
    }

    /// The number of rows started so far.
    size_t rowCount() const @safe pure nothrow @nogc => _rows.length;

    /**
    An owned snapshot. Text is copied once, not once per cell. The snapshot
    survives builder growth and destruction; its slices borrow from it.
    */
    TableCells cells() const scope @safe pure nothrow @nogc
    {
        TableCells result;
        result._text.put(_text[]);
        result._cells.reserve(_pending.length);
        result._rows.reserve(_rows.length);
        // These heap-only buffers never grow after their slices are published.
        // The text is private and never mutated again. All slices are bounded
        // by the returned owner's lifetime, including after an owner move.
        () @trusted
        {
            auto text = cast(string) result._text[];
            foreach (p; _pending[])
                result._cells.put(Cell(text[p.start .. p.end], p.colSpan,
                    p.rowSpan, p.halign, p.valign));
            foreach (r, start; _rows[])
            {
                const end = r + 1 < _rows.length ? _rows[r + 1] : _pending.length;
                result._rows.put(result._cells[start .. end]);
            }
        }();
        return result;
    }

    private ref TableBuilder add(Write)(scope Write write) return
    {
        if (_rows.length == 0)
            row();
        const start = _text[].length;
        write(_text);
        _pending.put(Pending(start, _text.length));
        return this;
    }

    private Pending* lastCell() return @safe pure nothrow @nogc
        => _rows.length && _pending.length > _rows[$ - 1] ? &_pending[$ - 1] : null;
}

/// Move-only dense cell snapshot returned by `TableBuilder.cells`.
struct TableCells
{
    private HeapBuffer!(char, Storage.unique) _text;
    private HeapBuffer!(Cell, Storage.unique) _cells;
    private HeapBuffer!(const(Cell)[], Storage.unique) _rows;

    /// Dense view, valid while this snapshot lives.
    const(Cell[][]) opSlice() const return scope @safe pure nothrow @nogc
        => _rows[];

    /// One row of the snapshot.
    const(Cell)[] opIndex(size_t row) const return scope @safe pure nothrow @nogc
        => _rows[row];

    /// Number of rows, including empty ones.
    size_t length() const @safe pure nothrow @nogc => _rows.length;
}

///
@("TableBuilder.cellsWrittenInPlace")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.text.writers : formatted, writeInteger;

    TableBuilder t;
    t.row("Name", "Runs");
    t.row.cell("build").cell!writeInteger(42);
    t.row("test", formatted!writeInteger(7));
    t.row.cell("total").span(2).aligned(Align.right);

    const cells = t.cells;
    assert(t.rowCount == 4);
    assert(cells[0][0].content == "Name" && cells[0][1].content == "Runs");
    assert(cells[1][1].content == "42");
    assert(cells[2][1].content == "7");
    assert(cells[3][0].colSpan == 2 && cells[3][0].halign == Align.right);
}

@("TableBuilder.cellsSurviveGrowth")
@safe pure nothrow @nogc unittest
{
    TableBuilder t;
    t.row("first");
    const before = t.cells;
    foreach (i; 0 .. 1000)
        t.row("padding that forces the buffer to move");
    assert(before[0][0].content == "first");
    assert(t.cells[0][0].content == "first");
}

@("TableBuilder.cellBeforeRowStartsOne")
@safe pure nothrow @nogc unittest
{
    TableBuilder t;
    t.cell("a").cell("b");
    assert(t.rowCount == 1 && t.cells[0].length == 2);
}

/// Snapshots own their storage, including after a move out of the builder's scope.
@("TableBuilder.snapshotOwnershipAndEmptyRows")
@safe pure nothrow @nogc unittest
{
    static TableCells snapshot() @safe pure nothrow @nogc
    {
        TableBuilder t;
        t.row.row("first").row;
        return t.cells;
    }

    auto cells = snapshot();
    assert(cells.length == 3);
    assert(cells[0].length == 0 && cells[2].length == 0);
    assert(cells[1][0].content == "first");
    TableBuilder empty;
    assert(empty.cells.length == 0);
}

/// Copying a builder copies offsets and text, not pointers into the original.
@("TableBuilder.copyIsIndependent")
@safe pure nothrow @nogc unittest
{
    TableBuilder original;
    original.row("first");
    auto copy = original;
    copy.cell("second").span(2);
    original.row("third");
    assert(original.cells[0].length == 1);
    assert(copy.cells.length == 1 && copy.cells[0].length == 2);
    assert(copy.cells[0][1].colSpan == 2);
}

/// Lazy lines retain their text after both the builder and snapshot are destroyed.
@("TableBuilder.linesOwnText")
@safe unittest
{
    import sparkles.ui.components.table.render : drawTableLines;

    static auto lines() @safe
    {
        TableBuilder t;
        t.row("first");
        return drawTableLines(t);
    }

    auto result = lines();
    result.popFront();
    assert(result.front == "│ first │");
}

@("TableBuilder.drawTableMatchesStringRows")
@safe unittest
{
    import std.array : appender;
    import sparkles.base.text.writers : formatted, writeInteger;
    import sparkles.ui.components.table.layout : TableProps;
    import sparkles.ui.components.table.render : drawTable;

    TableBuilder t;
    t.row("Name", "Runs").row("build", formatted!writeInteger(42));

    auto viaBuilder = appender!string;
    drawTable(viaBuilder, t, TableProps(headerRows: 1));
    auto viaRows = appender!string;
    drawTable(viaRows, [["Name", "Runs"], ["build", "42"]], TableProps(headerRows: 1));
    assert(viaBuilder[] == viaRows[]);
}
