/**
Abstract geometry for $(MREF sparkles,ui): points, sizes, rectangles, and insets
measured in $(B abstract cells) — the monospace column/row grid every backend
shares. An interpreter scales cells to pixels (GUI), keeps them 1:1 (TUI cell
grid), or maps them to `ch`/`em` (HTML). Nothing here knows about a specific
backend.

Also the sizing vocabulary ($(LREF SizeSpec): fit / grow / fixed / percent with
min/max) the layout pass ($(MREF sparkles,ui,layout)) resolves, and
$(LREF cellsOf) — the $(B one) width authority: the display-column width of a
string, counting one column per codepoint to match the grid advance the GUI
painter (`drawText`) and the terminal both use. (Proper wide/combining width is
the deferred grapheme-width upgrade; see the hue `FNT6`/`DEF7` roadmap item.)
*/
module sparkles.ui.geometry;

/// A position on the cell grid (column `x`, row `y`); may be negative for
/// off-viewport content.
struct Point
{
    int x;
    int y;
}

/// A size in cells (`w` columns × `h` rows).
struct Size
{
    int w;
    int h;
}

/// A rectangle on the cell grid, `[x, x+w) × [y, y+h)`.
struct Rect
{
    int x;
    int y;
    int w;
    int h;

@safe pure nothrow @nogc:

    /// The top-left corner.
    Point origin() const scope => Point(x, y);

    /// Right edge (exclusive) and bottom edge (exclusive).
    int right() const scope => x + w;
    /// ditto
    int bottom() const scope => y + h;

    /// `true` iff `p` lies inside the half-open rectangle.
    bool contains(in Point p) const scope
        => p.x >= x && p.x < x + w && p.y >= y && p.y < y + h;

    /// This rectangle shrunk by `ins` on each side (never below zero size).
    Rect deflate(in Insets ins) const scope
    {
        const nw = w - ins.left - ins.right;
        const nh = h - ins.top - ins.bottom;
        return Rect(x + ins.left, y + ins.top, nw > 0 ? nw : 0, nh > 0 ? nh : 0);
    }
}

/// Per-side padding/margin in cells (CSS order: top, right, bottom, left).
struct Insets
{
    int top;
    int right;
    int bottom;
    int left;

@safe pure nothrow @nogc:

    /// Uniform inset on all four sides.
    static Insets all(int n) => Insets(n, n, n, n);

    /// Vertical (top = bottom) and horizontal (left = right) insets.
    static Insets symmetric(int vertical, int horizontal)
        => Insets(vertical, horizontal, vertical, horizontal);

    /// Total horizontal / vertical inset.
    int horizontal() const scope => left + right;
    /// ditto
    int vertical() const scope => top + bottom;
}

/// How a widget claims space along one axis (the sizing vocabulary the layout
/// pass resolves). `fit` = shrink to content; `grow` = take remaining space
/// (weight `n`); `fixed` = exactly `n` cells; `percent` = `n`% of the parent.
struct SizeSpec
{
    /// The kind of sizing.
    enum Kind : ubyte
    {
        fit,     /// shrink-wrap the content
        grow,    /// fill remaining space, weighted by `value`
        fixed,   /// exactly `value` cells
        percent, /// `value`% of the available extent
    }

    Kind kind;
    int value;

    /// Optional clamps in cells (0 = unset for `min`, `int.max` for `max`).
    int min = 0;
    int max = int.max;

@safe pure nothrow @nogc:

    /// Shrink to content (the default).
    enum SizeSpec fit_ = SizeSpec(Kind.fit);
    /// Fill remaining space with weight `weight`.
    static SizeSpec grow(int weight = 1) => SizeSpec(Kind.grow, weight);
    /// Exactly `n` cells.
    static SizeSpec fixed(int n) => SizeSpec(Kind.fixed, n);
    /// `p` percent of the parent extent.
    static SizeSpec percent(int p) => SizeSpec(Kind.percent, p);

    /// Clamp `n` to `[min, max]`.
    int clamp(int n) const scope
        => n < min ? min : (n > max ? max : n);
}

/// The available space a layout pass fills — the extent (in cells) a widget may
/// grow into. `int.max` on an axis means unbounded (shrink-to-fit).
struct Constraints
{
    int maxW = int.max;
    int maxH = int.max;
}

/**
The display-column width of `s` — the $(B one) width authority for the whole
library, so the GUI painter, the TUI cell grid, and the layout pass never drift
sub-cell.

Counts one column per codepoint (a UTF-8 lead byte, i.e. every byte whose top
two bits are not `10`), matching the grid advance `drawText` and the terminal
use today. `@safe pure nothrow @nogc`; invalid UTF-8 degrades to a lead-byte
count rather than throwing.
*/
size_t cellsOf(scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t cols;
    foreach (char c; s)
        if ((c & 0xC0) != 0x80) // not a UTF-8 continuation byte → a new codepoint
            ++cols;
    return cols;
}

@("ui.geometry.cellsOf")
@safe pure nothrow @nogc
unittest
{
    assert(cellsOf("") == 0);
    assert(cellsOf("abc") == 3);
    assert(cellsOf("(property) title: string") == 24);
    // Multi-byte codepoints still count one column each (em dash, arrow).
    assert(cellsOf("a — b") == 5);
    assert(cellsOf("→") == 1);
}

@("ui.geometry.rect.containsAndDeflate")
@safe pure nothrow @nogc
unittest
{
    const r = Rect(2, 3, 10, 4);
    assert(r.contains(Point(2, 3)));
    assert(r.contains(Point(11, 6)));
    assert(!r.contains(Point(12, 3))); // right edge exclusive
    assert(!r.contains(Point(2, 7)));  // bottom edge exclusive

    const d = r.deflate(Insets.all(1));
    assert(d == Rect(3, 4, 8, 2));
    // Over-deflation clamps to zero, never negative.
    assert(Rect(0, 0, 1, 1).deflate(Insets.all(3)) == Rect(3, 3, 0, 0));
}

@("ui.geometry.sizeSpec.clampAndFactories")
@safe pure nothrow @nogc
unittest
{
    assert(SizeSpec.fixed(5).kind == SizeSpec.Kind.fixed);
    assert(SizeSpec.grow().value == 1);
    assert(SizeSpec.grow(3).value == 3);
    auto s = SizeSpec.fit_;
    s.min = 2;
    s.max = 8;
    assert(s.clamp(1) == 2);
    assert(s.clamp(5) == 5);
    assert(s.clamp(9) == 8);
}
