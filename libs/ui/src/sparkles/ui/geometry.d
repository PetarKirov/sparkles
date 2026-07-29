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

The 2-D types specialize $(MREF sparkles,math,vector)'s numeric `Vector`, the same
way $(REF TermSize, sparkles,core_cli,term_caps)/`TermPosition` do for the
terminal — one vector implementation and one field vocabulary across the stack.
*/
module sparkles.ui.geometry;

import sparkles.math : ScreenPosition, ScreenSize, Vector;

/**
The UI domain's canonical 2-D types: a position on the cell grid (`.x`/`.y`) and
an extent in cells (`.width`/`.height`). Reuse these instead of ad-hoc `int x, y;`
pairs.

Both are `int` — unlike the terminal's `ushort`
($(REF TermSize, sparkles,core_cli,term_caps)), a laid-out position may be
$(B negative) for content scrolled above or left of the viewport, and a document
may exceed 65535 cells. A size keeps $(REF ScreenSize, sparkles,math,vector)'s
`width`/`height` names rather than inventing `w`/`h`, so the whole repo spells an
extent one way.

$(B Note) these are `union`-backed (`Vector` overlays named fields on a
`T[N] data` array), so a named-field read is $(B not) available in CTFE — geometry
is a runtime vocabulary. `Point` keeps the default `x`/`y` names, so it also keeps
`Vector`'s `+`/`-`; `Size`'s custom names mean two `Size`s support `+=`/`-=` but
not `+`/`-` (no site needs it — every offset here is field-wise `int` math).
*/
alias Point = ScreenPosition!int;
/// ditto
alias Size = ScreenSize!int;

/// A rectangle on the cell grid, `[x, x+width) × [y, y+height)` — a
/// $(LREF Point) origin plus a $(LREF Size) extent.
struct Rect
{
    Point origin; /// the top-left corner
    Size size;    /// the extent, in cells

@safe pure nothrow @nogc:

    /// From an origin + extent, or from the four components directly (the
    /// spelling every call site uses).
    this(in Point origin, in Size size)
    {
        this.origin = origin;
        this.size = size;
    }

    /// ditto
    this(int x, int y, int width, int height)
    {
        origin = Point(x, y);
        size = Size(width, height);
    }

    /// The components, forwarded from `origin`/`size`.
    int x() const scope => origin.x;
    /// ditto
    int y() const scope => origin.y;
    /// ditto
    int width() const scope => size.width;
    /// ditto
    int height() const scope => size.height;

    /// Right edge (exclusive) and bottom edge (exclusive).
    int right() const scope => origin.x + size.width;
    /// ditto
    int bottom() const scope => origin.y + size.height;

    /// `true` iff `p` lies inside the half-open rectangle.
    bool contains(in Point p) const scope
        => p.x >= origin.x && p.x < right && p.y >= origin.y && p.y < bottom;

    /// This rectangle shrunk by `ins` on each side (never below zero size).
    Rect deflate(in Insets ins) const scope
    {
        const nw = size.width - ins.left - ins.right;
        const nh = size.height - ins.top - ins.bottom;
        return Rect(origin.x + ins.left, origin.y + ins.top,
            nw > 0 ? nw : 0, nh > 0 ? nh : 0);
    }
}

/**
Per-side insets in cells — padding, border widths (CSS order: top, right,
bottom, left). There is deliberately no `margin` (see
`docs/specs/ui/layout.md` § out of scope): `gap` + `padding` cover our cases.

A thin wrapper rather than a bare alias: `Vector`'s `opDispatch` swallows unknown
members, so the helpers below would become confusing swizzle errors on an alias.
`alias this` forwards the four side fields to the vector.
*/
struct Insets
{
    /// The four sides, in CSS order.
    Vector!(int, 4, ["top", "right", "bottom", "left"]) sides;
    alias sides this;

@safe pure nothrow @nogc:

    /// The four sides in CSS order (the wrapper needs its own constructor —
    /// otherwise a struct literal would try to fill `sides` alone).
    this(int top, int right, int bottom, int left)
    {
        sides = typeof(sides)(top, right, bottom, left);
    }

    /// Uniform inset on all four sides.
    static Insets all(int n) => Insets(n, n, n, n);

    /// Vertical (top = bottom) and horizontal (left = right) insets.
    static Insets symmetric(int vertical, int horizontal)
        => Insets(vertical, horizontal, vertical, horizontal);

    /// Total horizontal / vertical inset.
    int horizontal() const scope => sides.left + sides.right;
    /// ditto
    int vertical() const scope => sides.top + sides.bottom;
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

    // The two constructors agree, and the components forward to origin/size.
    assert(Rect(Point(2, 3), Size(10, 4)) == r);
    assert(r.x == 2 && r.y == 3 && r.width == 10 && r.height == 4);
    assert(r.origin == Point(2, 3) && r.size == Size(10, 4));
    assert(r.right == 12 && r.bottom == 7);
}

@("ui.geometry.insets.sidesAndTotals")
@safe pure nothrow @nogc
unittest
{
    const i = Insets(1, 2, 3, 4); // CSS order: top, right, bottom, left
    assert(i.top == 1 && i.right == 2 && i.bottom == 3 && i.left == 4);
    assert(i.horizontal == 6 && i.vertical == 4);

    assert(Insets.all(2) == Insets(2, 2, 2, 2));
    assert(Insets.symmetric(1, 5) == Insets(1, 5, 1, 5));
    assert(Insets.init == Insets(0, 0, 0, 0));
}

@("ui.geometry.point.vectorOps")
@safe pure nothrow @nogc
unittest
{
    // `Point` keeps `Vector`'s default `x`/`y` names, so it keeps `+`/`-`.
    assert(Point(1, 2) + Point(3, 4) == Point(4, 6));
    auto s = Size(3, 4);
    s += Size(1, 1); // custom-named vectors get `+=`, not `+`
    assert(s == Size(4, 5));
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
