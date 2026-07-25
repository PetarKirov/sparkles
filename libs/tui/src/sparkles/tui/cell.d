/++
The neutral target picture: a 2-D grid of styled cells.

This is the representation a widget tree paints into each frame and the ground
truth the renderer ($(MREF sparkles,tui,render)) diffs to a minimal byte stream.
A grid is exactly what a terminal displays, so the model is architecture-neutral:
draw into a $(LREF Grid), hand it to the renderer, and only the cells that changed
since the last frame are emitted.

The rendering core (2-D cell-grid with a compact packed cell) was chosen by the
[render-cost benchmark](../../../../../docs/specs/tui/render-bench-baseline.md);
this module is that benchmark's winning `cell.d` PoC, promoted into the library.

Style is a compact `TermStyle!false` (truecolor `Color` fg/bg, `TextAttr`, and an
`UnderlineStyle` shape — 8 bytes). SGR emission reuses the absolute reset-then-set
encoder $(REF writeStyle, sparkles,base,term_style) so a style-run is
self-establishing and trivial for a VT to reconstruct; the renderer coalesces it
per run so the byte cost stays realistic.
+/
module sparkles.tui.cell;

public import sparkles.base.term_color : Color, ColorDepth;
public import sparkles.base.term_style : CompactTermStyle, TextAttr, TermStyle,
    UnderlineStyle, writeStyle;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.utf : encodeUtf8, decodeFirstUtf8;
import sparkles.base.text.width : codepointWidth;

/// Compact cell style: 2 packed words (shaped layout minus the underline color).
alias CellStyle = CompactTermStyle;

/// One display cell: a grapheme cluster (inline UTF-8, up to `MaxBytes`), its
/// display width in columns (0/1/2), and its style. `MaxBytes` (default 16) bounds
/// the inline cluster — enough for CJK, most emoji, and short ZWJ sequences; longer
/// clusters are truncated (an edge case, not a correctness concern for the common
/// scenes). The default cell is a single styled space.
struct CellT(uint MaxBytes = 16)
{
    char[MaxBytes] bytes = ' ';
    ubyte len = 1;
    ubyte width = 1;
    CellStyle style;

    /// The grapheme cluster's bytes.
    const(char)[] grapheme() const @safe pure nothrow @nogc return => bytes[0 .. len];

    /// Set this cell to a single code point (encoded to UTF-8) with `width`.
    void setCodepoint(dchar cp, ubyte w, in CellStyle st) @safe pure nothrow @nogc
    {
        char[4] buf = void;
        const n = encodeUtf8(cp, buf);
        bytes[0 .. n] = buf[0 .. n];
        len = cast(ubyte) n;
        width = w;
        style = st;
    }

    /// Set this cell to an already-encoded cluster slice (truncated to fit).
    void setBytes(scope const(char)[] cluster, ubyte w, in CellStyle st) @safe pure nothrow @nogc
    {
        const n = cluster.length > MaxBytes ? MaxBytes : cluster.length;
        bytes[0 .. n] = cluster[0 .. n];
        len = cast(ubyte) n;
        width = w;
        style = st;
    }

    /// The first code point of this cell's grapheme (0x20 for a blank cell).
    uint codepoint() const scope @safe pure nothrow @nogc => decodeFirstUtf8(grapheme);

    bool opEquals(in CellT o) const @safe pure nothrow @nogc
        => len == o.len && width == o.width && style == o.style
            && bytes[0 .. len] == o.bytes[0 .. o.len];
}

/// The cell type used across the library — a `CellT` with the default 16-byte
/// inline cluster.
alias Cell = CellT!16;

/// A rectangular grid of cells, indexed `[x, y]` with `[0, 0]` top-left.
///
/// Move-only: its `SmallBuffer` backing is a sole-owner, GC-free heap block reused
/// across resizes, so a steady render loop allocates nothing. Copy explicitly via
/// the copy-constructor (`auto b = a;`) or capacity-reusing assignment (`b = a;`).
struct GridT(uint MaxBytes = 16)
{
    private
    {
        alias C = CellT!MaxBytes;
        // `unique` ⇒ sole-owner, move-only, GC-free; mutable access never clones.
        SmallBuffer!(C, 1, true) _cells;
        ushort _cols;
        ushort _rows;
    }

    /// Deep-copy constructor (the storage is otherwise move-only).
    this(ref const GridT other) @safe nothrow
    {
        assignFrom(other);
    }

    /// Deep-copy assignment, reusing this grid's capacity — the render loop's
    /// `_prev = target`, zero-allocation once capacity is established.
    void opAssign(ref const GridT other) @safe nothrow
    {
        assignFrom(other);
    }

    /// Column count.
    ushort cols() const scope @safe pure nothrow @nogc => _cols;
    /// Row count.
    ushort rows() const scope @safe pure nothrow @nogc => _rows;

    /// Resize (reusing capacity) and clear to blank cells.
    void resize(ushort cols, ushort rows) @safe nothrow
    {
        _cols = cols;
        _rows = rows;
        grow(count);
        clear();
    }

    /// Reset every live cell to a blank styled space.
    void clear() @safe nothrow
    {
        _cells[][0 .. count] = C.init;
    }

    /// Fill every live cell with a blank cell in `st` (e.g. a page background).
    void clearTo(in CellStyle st) @safe nothrow
    {
        C blank;
        blank.style = st;
        _cells[][0 .. count] = blank;
    }

    /// The cell at `[x, y]` (bounds-checked in `-debug`/unittest via the contract).
    ref C opIndex(ushort x, ushort y) return scope @safe pure nothrow @nogc
    in (x < _cols && y < _rows)
        => _cells[cast(size_t) y * _cols + x];

    /// ditto
    ref const(C) opIndex(ushort x, ushort y) const return scope @safe pure nothrow @nogc
    in (x < _cols && y < _rows)
        => _cells[cast(size_t) y * _cols + x];

    /// Row `y` as a mutable cell slice.
    C[] row(ushort y) return scope @safe pure nothrow @nogc
    in (y < _rows)
        => _cells[cast(size_t) y * _cols .. cast(size_t)(y + 1) * _cols];

    /// ditto (read-only)
    const(C)[] row(ushort y) const return scope @safe pure nothrow @nogc
    in (y < _rows)
        => _cells[cast(size_t) y * _cols .. cast(size_t)(y + 1) * _cols];

    /// Write a styled string starting at `(x, y)`, advancing by each code point's
    /// display width; stops at the right edge. Returns the next free x.
    ushort putText(ushort x, ushort y, scope const(char)[] text, in CellStyle st) @safe pure nothrow @nogc
    {
        import std.utf : byDchar;

        foreach (dchar cp; text.byDchar)
        {
            if (x >= _cols)
                break;
            const int w = codepointWidth(cp);
            if (w == 0)
                continue; // combining mark — cluster merge is out of scope here
            this[x, y].setCodepoint(cp, cast(ubyte) w, st);
            // A wide glyph occupies the next column with a zero-width continuation.
            if (w == 2 && x + 1 < _cols)
            {
                this[cast(ushort)(x + 1), y].setCodepoint(' ', 0, st);
                this[cast(ushort)(x + 1), y].width = 0;
            }
            x = cast(ushort)(x + w);
        }
        return x;
    }

    /// Fill a horizontal run `[x, x+n)` on row `y` with a styled space.
    void fill(ushort x, ushort y, ushort n, in CellStyle st) @safe pure nothrow @nogc
    {
        foreach (i; 0 .. n)
        {
            if (x + i >= _cols)
                break;
            this[cast(ushort)(x + i), y].setCodepoint(' ', 1, st);
        }
    }



    private:

    // Live cell count (cols*rows); the SmallBuffer may hold spare capacity beyond it.
    size_t count() const scope @safe pure nothrow @nogc => cast(size_t) _cols * _rows;

    // Ensure the buffer holds at least `n` cells (append blanks; capacity reused).
    void grow(size_t n) @safe nothrow
    {
        if (_cells.length >= n)
            return;
        _cells.reserve(n);
        foreach (_; _cells.length .. n)
            _cells.put(C.init);
    }

    // Deep-copy `other`'s dimensions + live cells into this (reusing capacity).
    void assignFrom(ref const GridT other) @safe nothrow
    {
        _cols = other._cols;
        _rows = other._rows;
        const n = count;
        grow(n);
        _cells[][0 .. n] = other._cells[][0 .. n];
    }

}

/// The grid type used across the library — cells with the default inline size.
alias Grid = GridT!16;

@("cell.grid.putTextAndWidth")
@safe nothrow
unittest
{
    Grid g;
    g.resize(10, 2);
    const st = CellStyle(fg: Color.fromRgb(255, 0, 0), attrs: TextAttr.bold);
    const nx = g.putText(0, 0, "hi", st);
    assert(nx == 2);
    assert(g[0, 0].grapheme == "h");
    assert(g[1, 0].style.attrs == TextAttr.bold);
    assert(g[2, 0].grapheme == " "); // untouched blank
    static assert(Cell.sizeof == 26);
    static assert(CellStyle.sizeof == 8);
}

@("cell.grid.wideGlyphContinuation")
@safe nothrow
unittest
{
    Grid g;
    g.resize(6, 1);
    // A wide (CJK) code point occupies two columns: the glyph + a zero-width cont.
    g.putText(0, 0, "世", CellStyle.init); // 世
    assert(g[0, 0].width == 2);
    assert(g[1, 0].width == 0); // continuation carries no bytes
}

@("cell.grid.copyAndAssign")
@safe nothrow
unittest
{
    Grid a;
    a.resize(4, 2);
    a.putText(0, 0, "hi", CellStyle.init);

    // Copy-constructor: an independent deep copy.
    auto b = a;
    assert(b[0, 0].grapheme == "h" && b.cols == 4 && b.rows == 2);
    b.putText(0, 0, "XY", CellStyle.init);
    assert(a[0, 0].grapheme == "h"); // original unaffected

    // Capacity-reusing assignment (the render loop's `_prev = target`).
    Grid c;
    c = a;
    assert(c[0, 0].grapheme == "h" && c[1, 0].grapheme == "i");
}
