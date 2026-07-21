/++
The neutral target picture: a 2-D grid of styled cells.

This is the representation the shared rendering spec (`scene.d`) produces from the
model each frame, and the ground truth the renderers are measured against. It is
deliberately architecture-neutral — a grid is exactly what a terminal displays —
so neither the line-diff nor the cell-grid PoC is flattered by the encoding: both
receive the identical target grid and differ only in how they turn a sequence of
grids into bytes.

Style is a truecolor-capable `CellStyle` (fg/bg/attrs), not
`sparkles.base.term_style.Style` (16-color SGR only): the scene paints with RGB,
which the benchmark must exercise to be realistic (spec C1). SGR emission lives
here so every renderer shares one honest encoder.
+/
module sparkles.tui_render_bench.cell;

import sparkles.tui_render_bench.sink : Sink;

/// A terminal color: terminal default, a 256-palette index, or 24-bit RGB.
struct Color
{
    ///
    enum Kind : ubyte
    {
        default_,
        indexed,
        rgb,
    }

    Kind kind = Kind.default_;
    ubyte a, b, c; // rgb: (r,g,b); indexed: index in `a`

    static Color rgb(ubyte r, ubyte g, ubyte b) @safe pure nothrow @nogc
        => Color(Kind.rgb, r, g, b);
    static Color indexed(ubyte i) @safe pure nothrow @nogc
        => Color(Kind.indexed, i, 0, 0);

    bool opEquals(in Color o) const @safe pure nothrow @nogc
    {
        if (kind != o.kind)
            return false;
        final switch (kind)
        {
            case Kind.default_: return true;
            case Kind.indexed: return a == o.a;
            case Kind.rgb: return a == o.a && b == o.b && c == o.c;
        }
    }
}

/// Text-attribute bits (OR them into `CellStyle.attrs`).
enum Attr : ubyte
{
    none = 0,
    bold = 1 << 0,
    dim = 1 << 1,
    italic = 1 << 2,
    underline = 1 << 3,
    reverse = 1 << 4,
}

/// A truecolor-capable cell style: foreground, background, attribute bits.
struct CellStyle
{
    Color fg;
    Color bg;
    ubyte attrs;

    bool opEquals(in CellStyle o) const @safe pure nothrow @nogc
        => fg == o.fg && bg == o.bg && attrs == o.attrs;
}

/// Longest inline grapheme cluster a cell stores (covers CJK, most emoji, and
/// short ZWJ sequences; longer clusters are truncated — a `unicode`-profile edge
/// case, not a correctness concern for the ASCII/CJK scenes).
enum maxCellBytes = 16;

/// One display cell: a grapheme cluster (inline UTF-8), its display width in
/// columns (0/1/2), and its style. The default cell is a single styled space.
struct Cell
{
    char[maxCellBytes] bytes = ' ';
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
        const n = cluster.length > maxCellBytes ? maxCellBytes : cluster.length;
        bytes[0 .. n] = cluster[0 .. n];
        len = cast(ubyte) n;
        width = w;
        style = st;
    }

    /// The first code point of this cell's grapheme (0x20 for a blank cell).
    uint codepoint() const scope @safe pure nothrow @nogc => firstCodepoint(grapheme);

    bool opEquals(in Cell o) const @safe pure nothrow @nogc
        => len == o.len && width == o.width && style == o.style
            && bytes[0 .. len] == o.bytes[0 .. o.len];
}

/// Decode the first code point of a (valid) UTF-8 grapheme; blank/empty → space.
uint firstCodepoint(scope const(char)[] g) @safe pure nothrow @nogc
{
    if (g.length == 0)
        return 0x20;
    const c0 = cast(ubyte) g[0];
    if (c0 < 0x80)
        return c0;
    if (c0 < 0xE0 && g.length >= 2)
        return ((c0 & 0x1F) << 6) | (cast(ubyte) g[1] & 0x3F);
    if (c0 < 0xF0 && g.length >= 3)
        return ((c0 & 0x0F) << 12) | ((cast(ubyte) g[1] & 0x3F) << 6) | (cast(ubyte) g[2] & 0x3F);
    if (g.length >= 4)
        return ((c0 & 0x07) << 18) | ((cast(ubyte) g[1] & 0x3F) << 12)
            | ((cast(ubyte) g[2] & 0x3F) << 6) | (cast(ubyte) g[3] & 0x3F);
    return 0xFFFD;
}

/// A rectangular grid of cells, indexed `(x, y)` with `(0, 0)` top-left.
struct Grid
{
    private
    {
        Cell[] _cells;
        ushort _cols;
        ushort _rows;
    }

    ///
    ushort cols() const scope @safe pure nothrow @nogc => _cols;
    ///
    ushort rows() const scope @safe pure nothrow @nogc => _rows;

    /// Resize (reusing capacity) and clear to blank cells.
    void resize(ushort cols, ushort rows) @safe nothrow
    {
        _cols = cols;
        _rows = rows;
        const n = cast(size_t) cols * rows;
        if (_cells.length < n)
            _cells.length = n;
        clear();
    }

    /// Reset every cell to a blank styled space.
    void clear() @safe pure nothrow @nogc
    {
        _cells[0 .. cast(size_t) _cols * _rows] = Cell.init;
    }

    /// Adopt `other`'s dimensions and cell contents (reusing capacity).
    void copyFrom(in Grid other) @safe nothrow
    {
        _cols = other._cols;
        _rows = other._rows;
        const n = cast(size_t) _cols * _rows;
        if (_cells.length < n)
            _cells.length = n;
        _cells[0 .. n] = other._cells[0 .. n];
    }

    /// The cell at `(x, y)` (no bounds checking in release).
    ref inout(Cell) at(ushort x, ushort y) inout return scope @safe pure nothrow @nogc
    in (x < _cols && y < _rows)
        => _cells[cast(size_t) y * _cols + x];

    /// Row `y` as a cell slice.
    inout(Cell)[] row(ushort y) inout return scope @safe pure nothrow @nogc
    in (y < _rows)
        => _cells[cast(size_t) y * _cols .. cast(size_t)(y + 1) * _cols];

    /// Write a styled string starting at `(x, y)`, advancing by each code
    /// point's display width; stops at the right edge. Returns the next free x.
    ushort putText(ushort x, ushort y, scope const(char)[] text, in CellStyle st) @safe pure nothrow @nogc
    {
        import std.utf : byDchar;

        foreach (dchar cp; text.byDchar)
        {
            if (x >= _cols)
                break;
            const int w = codepointCellWidth(cp);
            if (w == 0)
                continue; // combining mark — merge is out of scope for the bench scenes
            at(x, y).setCodepoint(cp, cast(ubyte) w, st);
            // A wide glyph occupies the next column with a zero-width continuation.
            if (w == 2 && x + 1 < _cols)
            {
                at(cast(ushort)(x + 1), y).setCodepoint(' ', 0, st);
                at(cast(ushort)(x + 1), y).width = 0;
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
            at(cast(ushort)(x + i), y).setCodepoint(' ', 1, st);
        }
    }
}

/// Display width of a code point in isolation (0/1/2), via the base width oracle.
int codepointCellWidth(dchar cp) @safe pure nothrow @nogc
{
    import sparkles.base.text.width : codepointWidth;

    const w = codepointWidth(cp);
    return w < 0 ? 1 : w; // control chars never reach the grid; clamp defensively
}

/// Encode a valid code point to UTF-8 (the `@nogc nothrow` path `std.utf.encode`
/// denies us — it can throw on surrogates, which the scenes never produce).
ubyte encodeUtf8(dchar cp, ref char[4] buf) @safe pure nothrow @nogc
{
    if (cp < 0x80)
    {
        buf[0] = cast(char) cp;
        return 1;
    }
    if (cp < 0x800)
    {
        buf[0] = cast(char)(0xC0 | (cp >> 6));
        buf[1] = cast(char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000)
    {
        buf[0] = cast(char)(0xE0 | (cp >> 12));
        buf[1] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = cast(char)(0x80 | (cp & 0x3F));
        return 3;
    }
    buf[0] = cast(char)(0xF0 | (cp >> 18));
    buf[1] = cast(char)(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = cast(char)(0x80 | (cp & 0x3F));
    return 4;
}

// ---------------------------------------------------------------------------
// SGR emission — one honest encoder shared by every renderer.
// ---------------------------------------------------------------------------

/// Emit `ESC[0;…m` establishing `st` from a clean slate (reset-then-set). Robust
/// and trivial for the VT oracle to reconstruct; renderers coalesce it per
/// style-run so the byte cost is realistic, not inflated per cell.
void writeStyle(ref Sink s, in CellStyle st) @safe nothrow
{
    s.put("\x1b[0");
    if (st.attrs & Attr.bold)
        s.put(";1");
    if (st.attrs & Attr.dim)
        s.put(";2");
    if (st.attrs & Attr.italic)
        s.put(";3");
    if (st.attrs & Attr.underline)
        s.put(";4");
    if (st.attrs & Attr.reverse)
        s.put(";7");
    writeColor(s, st.fg, true);
    writeColor(s, st.bg, false);
    s.put("m");
    s.sgrWrites++;
}

private void writeColor(ref Sink s, in Color c, bool fg) @safe nothrow
{
    final switch (c.kind)
    {
        case Color.Kind.default_:
            return; // 0m already selected the default; nothing to add
        case Color.Kind.indexed:
            s.put(fg ? ";38;5;" : ";48;5;");
            s.putUint(c.a);
            return;
        case Color.Kind.rgb:
            s.put(fg ? ";38;2;" : ";48;2;");
            s.putUint(c.a);
            s.put(";");
            s.putUint(c.b);
            s.put(";");
            s.putUint(c.c);
            return;
    }
}

@("cell.grid.putTextAndWidth")
@safe nothrow
unittest
{
    Grid g;
    g.resize(10, 2);
    const st = CellStyle(Color.rgb(255, 0, 0), Color.init, Attr.bold);
    const nx = g.putText(0, 0, "hi", st);
    assert(nx == 2);
    assert(g.at(0, 0).grapheme == "h");
    assert(g.at(1, 0).style.attrs == Attr.bold);
    assert(g.at(2, 0).grapheme == " "); // untouched blank
}

@("cell.writeStyle.rgbAndAttrs")
@safe nothrow
unittest
{
    Sink s;
    writeStyle(s, CellStyle(Color.rgb(10, 20, 30), Color.init, Attr.bold | Attr.underline));
    assert(s.frame == "\x1b[0;1;4;38;2;10;20;30m");
    assert(s.sgrWrites == 1);
}
