/// Pure text-metric and draw-decision helpers — the layout math shared by both
/// callers, decoupled from any GL so it is unit-tested directly.
module sparkles.raylib_text.metrics;

@safe:

/// Cell-metric zero-guard: a degenerate font metric of `< 1` px would divide
/// every grid computation by zero, so clamp to 1.
int guardCell(float measured) pure nothrow @nogc
    => measured < 1.0f ? 1 : cast(int) measured;

///
@("raylib_text.guardCell.clamp")
pure nothrow @nogc
unittest
{
    assert(guardCell(0) == 1);
    assert(guardCell(0.4f) == 1);
    assert(guardCell(-3) == 1);
    assert(guardCell(12.9f) == 12);
    assert(guardCell(20) == 20);
}

/// The monospace column width of a UTF-8 run: the number of codepoints (each
/// non-continuation byte begins one). A fixed cell advance keeps runs on a
/// perfect grid — unlike `MeasureTextEx`, which sums glyph advances and drifts.
/// Combining marks and wide/tab characters count as one column (a v1 limit).
size_t columnWidth(scope const(char)[] run) pure nothrow @nogc
{
    size_t cols;
    foreach (ubyte c; run)
        if ((c & 0xC0) != 0x80) // not a UTF-8 continuation byte
            ++cols;
    return cols;
}

///
@("raylib_text.columnWidth.codepoints")
pure nothrow @nogc
unittest
{
    assert(columnWidth("") == 0);
    assert(columnWidth("main()") == 6);
    assert(columnWidth("  int") == 5);
    assert(columnWidth("a\u2192b") == 3); // '\u2192' is one 3-byte codepoint
    assert(columnWidth("\u00e9") == 1);    // precomposed \u00e9: one codepoint
    assert(columnWidth("e\u0301") == 2);   // decomposed: base + combining mark
}

/// Encodes a grapheme cluster (base codepoint plus any combining marks, ZWJ
/// joiners, variation selectors — at most 16) into a single NUL-terminated
/// UTF-8 buffer, so raylib's `DrawTextEx` draws it as one unit. Invalid
/// codepoints become U+FFFD; buffer overflow stops cleanly. Returns the slice
/// up to (not including) the terminating NUL — `result.ptr[result.length]` is
/// `'\0'`. This is apps/terminal's per-cell need.
const(char)[] encodeGraphemeCluster(scope const(uint)[] codepoints, return ref char[64] buf)
    pure nothrow @nogc
{
    import std.utf : encode;
    import std.typecons : Yes;

    size_t len;
    const n = codepoints.length < 16 ? codepoints.length : 16;
    foreach (i; 0 .. n)
    {
        char[4] u8 = void;
        const u8n = encode!(Yes.useReplacementDchar)(u8, cast(dchar) codepoints[i]);
        if (len + u8n >= buf.length) // keep room for the NUL
            break;
        buf[len .. len + u8n] = u8[0 .. u8n];
        len += u8n;
    }
    buf[len] = '\0';
    return buf[0 .. len];
}

///
@("raylib_text.encodeGraphemeCluster.cases")
pure nothrow @nogc
unittest
{
    char[64] buf = void;

    assert(encodeGraphemeCluster([cast(uint) 'M'], buf) == "M");
    assert(buf[1] == '\0');

    const acute = encodeGraphemeCluster([cast(uint) 'e', 0x0301], buf);
    assert(acute.length == 3 && acute[0] == 'e');
    assert(buf[acute.length] == '\0');

    uint[32] many = 'a';
    assert(encodeGraphemeCluster(many[], buf).length == 16);

    uint[64] wide = 0x2192; // 3 bytes each
    const clipped = encodeGraphemeCluster(wide[], buf);
    assert(clipped.length < buf.length && buf[clipped.length] == '\0');
}
