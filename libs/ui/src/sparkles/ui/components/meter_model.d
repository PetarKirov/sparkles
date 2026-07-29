/++
The presentation-free half of the meter: a fraction and a width in, a cell
budget out. No glyphs.

Splitting this from the writer is what makes the fill rule testable on its own
— the rounding, the carry when a partial cell rounds up to a whole one, and the
`width`-exact padding are arithmetic, not rendering. A view then picks glyphs
for the three counts.
+/
module sparkles.ui.components.meter_model;

@safe:

/**
How a `width`-cell bar divides up.

$(D full + (eighth ? 1 : 0) + empty == width) always holds, so a renderer that
emits one glyph per counted cell fills exactly `width` cells.
*/
struct MeterFill
{
    size_t full;   /// cells drawn with the full glyph
    size_t eighth; /// eighths of the one partial cell; `0` when there is none
    size_t empty;  /// cells drawn with the empty glyph
}

/**
Divides a `width`-cell bar filled to `fraction` (clamped to `[0, 1]`; NaN reads
as empty).

`subCell` says whether the charset has the eighth-block glyphs. Without them a
fractional remainder cannot be drawn, so it becomes padding — which is why this
is a model input and not a rendering detail: it changes the counts.

A remainder that rounds up to a whole cell is carried into `full`, so the bar
never shows a "full" partial glyph.
*/
MeterFill meterFill(double fraction, size_t width, bool subCell = true) pure nothrow @nogc
{
    if (fraction < 0 || fraction != fraction) // NaN guards as empty
        fraction = 0;
    if (fraction > 1)
        fraction = 1;

    const cells = fraction * width;
    size_t full = cast(size_t) cells;
    const eighth = cast(size_t) ((cells - full) * 8 + 0.5);

    size_t used = full;
    size_t partial;
    if (used < width && eighth > 0 && eighth < 8 && subCell)
    {
        partial = eighth;
        used++;
    }
    else if (used < width && eighth == 8)
    {
        full++; // rounding carried the partial cell to a full one
        used++;
    }
    return MeterFill(full: full, eighth: partial, empty: width - used);
}

@("meter_model.meterFill.widthExact")
@safe pure nothrow @nogc
unittest
{
    // The three counts always tile the width exactly, at any fraction.
    foreach (width; [0, 1, 3, 8, 40])
        foreach (i; 0 .. 101)
        {
            const f = meterFill(i / 100.0, width);
            assert(f.full + (f.eighth ? 1 : 0) + f.empty == width);
        }
}

@("meter_model.meterFill.boundsAndNaN")
@safe pure nothrow @nogc
unittest
{
    assert(meterFill(0.0, 4) == MeterFill(full: 0, eighth: 0, empty: 4));
    assert(meterFill(1.0, 4) == MeterFill(full: 4, eighth: 0, empty: 0));
    assert(meterFill(-1.0, 4) == MeterFill(full: 0, eighth: 0, empty: 4)); // clamped
    assert(meterFill(2.0, 4) == MeterFill(full: 4, eighth: 0, empty: 0));  // clamped
    assert(meterFill(double.nan, 4) == MeterFill(full: 0, eighth: 0, empty: 4));
}

@("meter_model.meterFill.partialCell")
@safe pure nothrow @nogc
unittest
{
    // Half of one cell is four eighths.
    assert(meterFill(0.5, 1) == MeterFill(full: 0, eighth: 4, empty: 0));
    // Without sub-cell glyphs the remainder cannot be drawn, so it pads.
    assert(meterFill(0.5, 1, false) == MeterFill(full: 0, eighth: 0, empty: 1));
}

@("meter_model.meterFill.roundingCarry")
@safe pure nothrow @nogc
unittest
{
    // 0.99 of one cell rounds to eight eighths — a whole cell, not a partial
    // glyph that looks full.
    const f = meterFill(0.99, 1);
    assert(f == MeterFill(full: 1, eighth: 0, empty: 0));
}
