/++
A grid fingerprint: a 64-bit hash of every cell's grapheme, width, and style.

It is how correctness is checked without depending on the exact bytes a renderer
emits — line-diff and cell-diff legitimately produce different ANSI for the same
picture. Two grids with equal fingerprints are the same picture; the correctness
gate (`vt_oracle.d`) compares the fingerprint of the grid a VT reconstructs from a
renderer's bytes against the fingerprint of the target grid.
+/
module sparkles.tui_render_bench.fingerprint;

import sparkles.tui_render_bench.cell : Cell, CellStyle, Color, Grid;

/// FNV-1a over the full grid (dimensions + every cell).
ulong gridFingerprint(in Grid g) @safe pure nothrow @nogc
{
    ulong h = 0xCBF29CE484222325UL;

    void mix(ubyte b) @safe pure nothrow @nogc
    {
        h ^= b;
        h *= 0x0000_0100_0000_01B3UL;
    }

    void mix16(ushort v) @safe pure nothrow @nogc
    {
        mix(cast(ubyte)(v & 0xFF));
        mix(cast(ubyte)(v >> 8));
    }

    void mixColor(in Color c) @safe pure nothrow @nogc
    {
        mix(cast(ubyte) c.kind);
        final switch (c.kind)
        {
            case Color.Kind.unset:
            case Color.Kind.default_:
                mix(0);
                mix(0);
                mix(0);
                return;
            case Color.Kind.palette:
                mix(c.index);
                mix(0);
                mix(0);
                return;
            case Color.Kind.rgb:
                mix(c.rgb.r);
                mix(c.rgb.g);
                mix(c.rgb.b);
                return;
        }
    }

    void mixStyle(in CellStyle st) @safe pure nothrow @nogc
    {
        mixColor(st.fg);
        mixColor(st.bg);
        mix(st.attrs.bits);
        mix(cast(ubyte) st.underline);
    }

    mix16(g.cols);
    mix16(g.rows);
    foreach (ushort y; 0 .. g.rows)
        foreach (const ref Cell cell; g.row(y))
        {
            mix(cell.width);
            foreach (ch; cell.grapheme)
                mix(cast(ubyte) ch);
            mixStyle(cell.style);
        }
    return h;
}

@("fingerprint.grid.sensitiveToContentAndStyle")
@safe nothrow
unittest
{
    Grid a, b;
    a.resize(8, 2);
    b.resize(8, 2);
    assert(gridFingerprint(a) == gridFingerprint(b)); // both blank

    b.putText(0, 0, "x", CellStyle.init);
    assert(gridFingerprint(a) != gridFingerprint(b)); // content differs

    a.putText(0, 0, "x", CellStyle(fg: Color.fromRgb(1, 0, 0)));
    assert(gridFingerprint(a) != gridFingerprint(b)); // same glyph, different color
}
