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

/// Width of a UTF-8 run in owned terminal cells, matching `drawText` cluster
/// occupancy. ANSI escapes and controls occupy zero cells; malformed UTF-8 uses
/// owned maximal-subpart replacement.
size_t columnWidth(scope const(char)[] run) pure nothrow @nogc
{
    import sparkles.base.text.grapheme : visibleWidth;

    return visibleWidth(run);
}
