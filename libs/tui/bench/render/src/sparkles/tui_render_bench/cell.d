/++
The neutral target picture: a 2-D grid of styled cells.

This is the representation the shared rendering spec (`scene.d`) produces from the
model each frame, and the ground truth the renderers are measured against. It is
deliberately architecture-neutral — a grid is exactly what a terminal displays —
so neither the line-diff nor the cell-grid PoC is flattered by the encoding: both
receive the identical target grid and differ only in how they turn a sequence of
grids into bytes.

Style is `sparkles.base.term_style.TermStyle` (truecolor-capable `Color` fg/bg,
`TextAttr`, underline shape). The scene paints with RGB, which the benchmark must
exercise to be realistic (spec C1). SGR emission uses the same absolute
reset-then-set encoder every renderer shares, so byte streams stay comparable
across PoCs (and with the C calibration shim).
+/
module sparkles.tui_render_bench.cell;

public import sparkles.base.term_color : Color;
public import sparkles.base.term_style : TermStyle, TextAttr, UnderlineStyle;

import sparkles.base.term_color : ColorChannel, ColorDepth, writeSgrColorPacked;
import sparkles.tui_render_bench.sink : Sink;

// Layout constants matching `sparkles.base.term_style` packing (bits 0–25 color,
// 26–31 attrs/underline). Kept local so the emit path never materializes Color.
private enum uint colorBits = 26;
private enum uint colorMask = (1u << colorBits) - 1;
private enum ubyte attrsMask = 0x3F;
private enum ubyte underlineMask = 0x07;

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
    TermStyle style;

    /// The grapheme cluster's bytes.
    const(char)[] grapheme() const @safe pure nothrow @nogc return => bytes[0 .. len];

    /// Set this cell to a single code point (encoded to UTF-8) with `width`.
    void setCodepoint(dchar cp, ubyte w, in TermStyle st) @safe pure nothrow @nogc
    {
        char[4] buf = void;
        const n = encodeUtf8(cp, buf);
        bytes[0 .. n] = buf[0 .. n];
        len = cast(ubyte) n;
        width = w;
        style = st;
    }

    /// Set this cell to an already-encoded cluster slice (truncated to fit).
    void setBytes(scope const(char)[] cluster, ubyte w, in TermStyle st) @safe pure nothrow @nogc
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
    ushort putText(ushort x, ushort y, scope const(char)[] text, in TermStyle st) @safe pure nothrow @nogc
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
    void fill(ushort x, ushort y, ushort n, in TermStyle st) @safe pure nothrow @nogc
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
///
/// Colors go through `writeSgrColorPacked` on the raw `TermStyle` words — no
/// `Color` is materialized on this path. Unset/default colors are omitted (the
/// leading `0` already selected them).
void writeStyle(ref Sink s, in TermStyle st) @safe nothrow
{
    s.put("\x1b[0");
    const w0 = st.packed0;
    const w1 = st.packed1;
    const attrs = cast(ubyte)((w0 >> colorBits) & attrsMask);
    if (attrs & TextAttr.bold.bits)
        s.put(";1");
    if (attrs & TextAttr.dim.bits)
        s.put(";2");
    if (attrs & TextAttr.italic.bits)
        s.put(";3");
    // Underline shape (scene uses `single`; extended shapes use colon form).
    final switch (cast(UnderlineStyle)((w1 >> colorBits) & underlineMask))
    {
        case UnderlineStyle.none:
            break;
        case UnderlineStyle.single:
            s.put(";4");
            break;
        case UnderlineStyle.double_:
            s.put(";4:2");
            break;
        case UnderlineStyle.curly:
            s.put(";4:3");
            break;
        case UnderlineStyle.dotted:
            s.put(";4:4");
            break;
        case UnderlineStyle.dashed:
            s.put(";4:5");
            break;
    }
    if (attrs & TextAttr.inverse.bits)
        s.put(";7");
    if (attrs & TextAttr.hidden.bits)
        s.put(";8");
    if (attrs & TextAttr.strikethrough.bits)
        s.put(";9");
    writeStyleColorPacked(s, w0, ColorChannel.foreground);
    writeStyleColorPacked(s, w1, ColorChannel.background);
    s.put("m");
    s.sgrWrites++;
}

/// Append a packed color as SGR parameters after a leading `;`, skipping
/// unset/default (the absolute `0` reset already selected the terminal defaults).
private void writeStyleColorPacked(ref Sink s, uint packedWord, ColorChannel channel) @safe nothrow
{
    // Kind tag lives in bits 24–25 of the packColor payload (low 26 bits).
    const kind = (packedWord >> 24) & 3;
    if (kind == Color.Kind.unset || kind == Color.Kind.default_)
        return;
    s.put(';');
    writeSgrColorPacked(s, packedWord, ColorDepth.trueColor, channel);
}

/// Pack a packed-color word into the C calibration ABI tag: 0 = none/default,
/// 1 = palette, 2 = rgb (matches ghostty's style-color tags and the C `TuiCell`
/// layout). Reads only the `packColor` kind in bits 24–25 — no `Color` unpack.
ubyte calibColorTagPacked(uint packedWord) @safe pure nothrow @nogc
{
    final switch ((packedWord >> 24) & 3)
    {
        case 0: // Color.Kind.unset
        case 1: // Color.Kind.default_
            return 0;
        case 2: // Color.Kind.palette
            return 1;
        case 3: // Color.Kind.rgb
            return 2;
    }
}

/// RGB/palette payload bytes for the C calibration ABI from a packed word.
void calibColorPayloadPacked(uint packedWord, out ubyte a, out ubyte b, out ubyte cc)
    @safe pure nothrow @nogc
{
    final switch ((packedWord >> 24) & 3)
    {
        case 0: // unset
        case 1: // default_
            a = b = cc = 0;
            return;
        case 2: // palette
            a = cast(ubyte)(packedWord & 0xFF);
            b = cc = 0;
            return;
        case 3: // rgb
            a = cast(ubyte)(packedWord >> 16);
            b = cast(ubyte)(packedWord >> 8);
            cc = cast(ubyte) packedWord;
            return;
    }
}

/// Canonical attribute bits for calibration / VT oracle: bold=1, dim=2,
/// italic=4, underline=8, reverse=16. Reads packed words only.
ubyte calibAttrs(in TermStyle st) @safe pure nothrow @nogc
{
    const attrs = cast(ubyte)((st.packed0 >> colorBits) & attrsMask);
    ubyte a;
    if (attrs & TextAttr.bold.bits)
        a |= 1;
    if (attrs & TextAttr.dim.bits)
        a |= 2;
    if (attrs & TextAttr.italic.bits)
        a |= 4;
    if (((st.packed1 >> colorBits) & underlineMask) != 0)
        a |= 8;
    if (attrs & TextAttr.inverse.bits)
        a |= 16;
    return a;
}

/// Fill C-ABI color + attr fields from a `TermStyle` without unpacking `Color`.
void calibFillStyle(in TermStyle st, out ubyte fgKind, out ubyte fr, out ubyte fg, out ubyte fb,
    out ubyte bgKind, out ubyte br, out ubyte bg, out ubyte bb, out ubyte attrs)
    @safe pure nothrow @nogc
{
    fgKind = calibColorTagPacked(st.packed0);
    calibColorPayloadPacked(st.packed0, fr, fg, fb);
    bgKind = calibColorTagPacked(st.packed1);
    calibColorPayloadPacked(st.packed1, br, bg, bb);
    attrs = calibAttrs(st);
}

@("cell.grid.putTextAndWidth")
@safe nothrow
unittest
{
    Grid g;
    g.resize(10, 2);
    const st = TermStyle(fg: Color.fromRgb(255, 0, 0), attrs: TextAttr.bold);
    const nx = g.putText(0, 0, "hi", st);
    assert(nx == 2);
    assert(g.at(0, 0).grapheme == "h");
    assert(g.at(1, 0).style.attrs == TextAttr.bold);
    assert(g.at(2, 0).grapheme == " "); // untouched blank
}

@("cell.writeStyle.rgbAndAttrs")
@safe nothrow
unittest
{
    Sink s;
    writeStyle(s, TermStyle(
        fg: Color.fromRgb(10, 20, 30),
        attrs: TextAttr.bold,
        underline: UnderlineStyle.single));
    assert(s.frame == "\x1b[0;1;4;38;2;10;20;30m");
    assert(s.sgrWrites == 1);
}
