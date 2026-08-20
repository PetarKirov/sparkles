/**
Device-pixel to toolkit-cell conversion shared by every pixel input producer.

The mapping must be the same mapping the canvas paints with: if an adapter
independently rounds or applies its origin, a pointer lands beside the cell it
visually names. `CellMetrics` therefore lives with the shared input vocabulary,
not in a particular windowing backend.
*/
module sparkles.input.metrics;

import sparkles.input.events : Point;

@safe:

/// The cells-to-device mapping used by a pixel input producer.
struct CellMetrics
{
    int cellW = 1; /// device pixels per cell column
    int cellH = 1; /// device pixels per cell row
    int originX;   /// device-space x coordinate of cell `(0, 0)`
    int originY;   /// device-space y coordinate of cell `(0, 0)`

    /// Convert a device-space position to a 0-based toolkit cell.
    Point toCell(float px, float py) const pure nothrow @nogc
        => Point(
            (cast(int) px - originX) / positiveOrOne(cellW),
            (cast(int) py - originY) / positiveOrOne(cellH));

    /// Convert a device-space position already represented as integers.
    Point toCell(int px, int py) const pure nothrow @nogc
        => Point(
            (px - originX) / positiveOrOne(cellW),
            (py - originY) / positiveOrOne(cellH));
}

private int positiveOrOne(int value) pure nothrow @nogc
    => value > 0 ? value : 1;

@("input.metrics.mapsDevicePixelsOnce")
pure nothrow @nogc
unittest
{
    const m = CellMetrics(cellW: 8, cellH: 16, originX: 3, originY: 5);
    assert(m.toCell(19, 37) == Point(2, 2));
    assert(m.toCell(19.9f, 37.9f) == Point(2, 2));

    // A temporarily invalid metric degrades to the identity divisor rather
    // than dividing by zero. Both existing producers used this rule.
    const invalid = CellMetrics(cellW: 0, cellH: -2);
    assert(invalid.toCell(4, 7) == Point(4, 7));
}
