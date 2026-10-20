/**
Where a pixel canvas puts the pixels of box chrome: borders, rules, lines,
scrollbar rails, shadows, popup arrows, drawn sizes, shifts and clips.

The toolkit speaks cells; a pixel canvas maps a cell `(x, y)` to
`(originX + x·cellW, originY + y·cellH)` and then has to decide, for every
piece of chrome thinner than a cell, which device pixels it covers. Two
canvases that each decide that for themselves disagree by a pixel within a
release — a dash one pixel later, a thumb one pixel shorter — and nothing
but a screenshot notices. So the decisions live here, as pure integer
functions every pixel canvas calls (`sparkles:ui-vulkan` `UVK10`, decision
`UVX7`), and each states its rounding.

Rectangles are $(REF Rect, sparkles,ui,geometry) in device pixels. Border
strokes are naturally half-pixels — a stroke centred in a cell column of odd
width — and are computed exactly in half-pixel units, then truncated: each of
`x`, `y`, `width` and `height` rounded toward zero on its own.

Rounded corners and arrow edges are not pixel sets: a canvas draws them with
coverage, and only the shapes they bound come from here.
*/
module sparkles.ui.pixel_geometry;

import sparkles.ui.canvas : RuleEdge, Scrollbar;
import sparkles.ui.geometry : Insets, Rect;
import sparkles.ui.state : scrollbarThumb;
import sparkles.ui.style : BorderStyle, Shadow;

// ---------------------------------------------------------------------------
// Lengths
// ---------------------------------------------------------------------------

/// A length the toolkit gives in CSS pixels — a radius, a shadow offset, a
/// drawn size — in device pixels at `density`, rounded half away from zero.
int densityPx(int css, float density) @safe pure nothrow @nogc
    => cast(int)(css * density + (css >= 0 ? 0.5f : -0.5f));

///
@("pixelGeometry.densityPx.roundsHalfAwayFromZero")
@safe pure nothrow @nogc
unittest
{
    assert(densityPx(16, 2.75f) == 44);
    assert(densityPx(4, 2.75f) == 11);
    assert(densityPx(-4, 2.75f) == -11);
    assert(densityPx(1, 1.5f) == 2 && densityPx(-1, 1.5f) == -2);
    assert(densityPx(12, 1) == 12);
}

/// A shift of `cells` — a fraction of a cell (`LAY7`) — in whole device
/// pixels of a `cell`-pixel cell, rounded half away from zero, so glyphs
/// under it rasterise identically at every offset and a hit test can undo
/// exactly what was painted.
int shiftPx(float cells, int cell) @safe pure nothrow @nogc
{
    const v = cells * cell;
    return cast(int)(v < 0 ? -cast(long)(-v + 0.5f) : cast(long)(v + 0.5f));
}

///
@("pixelGeometry.shiftPx.roundsHalfAwayFromZero")
@safe pure nothrow @nogc
unittest
{
    assert(shiftPx(-0.5f, 20) == -10);
    assert(shiftPx(-0.26f, 20) == -5, "rounded to a whole pixel");
    assert(shiftPx(0.5f, 9) == 5 && shiftPx(-0.5f, 9) == -5, "half a 9 px cell");
}

/**
Shrinks the span `[start, start + extent)` to `drawn` pixels centred in it
(`TOK11`), the slack halved and truncated; a `drawn` of 0, or one at least
`extent`, leaves the span whole. A box with an explicit drawn size is its rect
with this applied to each axis.
*/
void centredSpan(ref int start, ref int extent, int drawn) @safe pure nothrow @nogc
{
    if (drawn <= 0 || drawn >= extent)
        return;
    start += (extent - drawn) / 2;
    extent = drawn;
}

///
@("pixelGeometry.centredSpan")
@safe pure nothrow @nogc
unittest
{
    int y = 100, h = 132; // 3 rows of 44 px
    centredSpan(y, h, 88);  // a 32 dp chip at 2.75 px/dp
    assert(y == 122 && h == 88);
    y = 0, h = 21;
    centredSpan(y, h, 10);
    assert(y == 5 && h == 10, "odd slack: truncated");
    y = 0, h = 20;
    centredSpan(y, h, 0);
    assert(y == 0 && h == 20, "0: the whole rect");
    centredSpan(y, h, 40);
    assert(y == 0 && h == 20, "taller than the rect: the whole rect");
}

// ---------------------------------------------------------------------------
// Rules and lines
// ---------------------------------------------------------------------------

/// The one-device-pixel rule along `edge` of `box` (`UIA2`): the outermost
/// row or column of pixels on that edge, or the middle one — at `width / 2`
/// or `height / 2`, truncated — for `centerX` and `centerY`.
Rect ruleRect(in Rect box, RuleEdge edge) @safe pure nothrow @nogc
{
    final switch (edge) with (RuleEdge)
    {
        case top:     return Rect(box.x, box.y, box.width, 1);
        case bottom:  return Rect(box.x, box.y + box.height - 1, box.width, 1);
        case left:    return Rect(box.x, box.y, 1, box.height);
        case right:   return Rect(box.x + box.width - 1, box.y, 1, box.height);
        case centerX: return Rect(box.x + box.width / 2, box.y, 1, box.height);
        case centerY: return Rect(box.x, box.y + box.height / 2, box.width, 1);
    }
}

///
@("pixelGeometry.ruleRect.eachEdge")
@safe pure nothrow @nogc
unittest
{
    const box = Rect(10, 20, 9, 7);
    assert(ruleRect(box, RuleEdge.top) == Rect(10, 20, 9, 1));
    assert(ruleRect(box, RuleEdge.bottom) == Rect(10, 26, 9, 1));
    assert(ruleRect(box, RuleEdge.left) == Rect(10, 20, 1, 7));
    assert(ruleRect(box, RuleEdge.right) == Rect(18, 20, 1, 7));
    assert(ruleRect(box, RuleEdge.centerX) == Rect(14, 20, 1, 7));
    assert(ruleRect(box, RuleEdge.centerY) == Rect(10, 23, 9, 1));
}

/**
Calls `sink(Rect)` with the pixels of a line from `(x0, y0)` to `x1` on the
same row, for a cell `cellH` pixels tall. A solid line is one pixel high
across `[x0, x1)`. A wavy line — the error squiggle — is two-pixel segments
every four pixels, the last one cut at `x1`, on the row two pixels above the
cell's bottom. Only horizontal lines have pixels: the toolkit draws no other.

The squiggle was meant to alternate between that row and the one below it,
but the reference canvas's offset, `i / 2 % 2` for `i` a multiple of four,
was always zero; this keeps the dashes it has always drawn.
*/
void lineRects(Sink)(int x0, int y0, int x1, bool wavy, int cellH, scope Sink sink)
{
    const w = x1 - x0;
    if (w <= 0)
        return;
    if (!wavy)
        return sink(Rect(x0, y0, w, 1));
    const baseY = y0 + cellH - 2;
    for (int i = 0; i < w; i += 4)
        sink(Rect(x0 + i, baseY, i + 2 <= w ? 2 : w - i, 1));
}

///
@("pixelGeometry.lineRects.solidAndWavy")
@safe pure nothrow @nogc
unittest
{
    Rect[4] got;
    size_t n;
    lineRects(5, 10, 15, false, 16, (Rect r) { got[n++] = r; });
    assert(n == 1 && got[0] == Rect(5, 10, 10, 1));

    n = 0;
    lineRects(0, 0, 11, true, 16, (Rect r) { got[n++] = r; });
    assert(n == 3);
    assert(got[0] == Rect(0, 14, 2, 1) && got[1] == Rect(4, 14, 2, 1),
        "two pixels every four, two rows above the cell's bottom");
    assert(got[2] == Rect(8, 14, 2, 1));

    n = 0;
    lineRects(0, 0, 9, true, 16, (Rect r) { got[n++] = r; });
    assert(got[n - 1] == Rect(8, 14, 1, 1), "the last segment cut at the end");

    n = 0;
    lineRects(0, 0, 0, true, 16, (Rect r) { got[n++] = r; });
    assert(n == 0);
}

// ---------------------------------------------------------------------------
// Borders
// ---------------------------------------------------------------------------

/// The stroke thickness, in pixels, of a border side of weight 1 on a
/// `cellW`×`cellH` cell: the arm of a light box-drawing glyph, a fourteenth of
/// the cell's shorter side, at least one pixel.
int borderUnit(int cellW, int cellH) @safe pure nothrow @nogc
{
    const md = cellW < cellH ? cellW : cellH;
    return md / 14 < 1 ? 1 : md / 14;
}

/**
Calls `sink(Rect)` with the pixels of a square border of `style` around
`box`, sides of weight `width` (in units of $(LREF borderUnit)), on a
`cellW`×`cellH` cell grid.

A solid or double border draws as the terminal's box-drawing glyphs do: a
vertical stroke centred in its border column, and, when the box has a
vertical side, each horizontal centred in its row, every stroke ending at the
outer face of the one it meets, so each corner is a `┌`. A double border is
two such boxes `1.5t` either side of the single border's centre lines, or,
without a vertical side, its second stroke `2t` inward (`t` the thickest
side). A dotted or dashed border straddles the box's edges with dashes along
each edge's long axis: dots as long as the stroke is thick, with gaps as
long; dashes three times that, with gaps twice.

Strokes are computed in half pixels and truncated. Sides of weight 0 draw
nothing.
*/
void borderRects(Sink)(in Rect box, in Insets width, BorderStyle style, int cellW,
    int cellH, scope Sink sink)
{
    if (style == BorderStyle.none)
        return;
    const unit = borderUnit(cellW, cellH);
    const boxed = style == BorderStyle.solid || style == BorderStyle.double_;
    const inset2 = boxed ? cellW : 0;
    const insetY2 = boxed && (width.left || width.right) ? cellH : 0;
    const x2 = 2 * box.x, y2 = 2 * box.y, w2 = 2 * box.width, h2 = 2 * box.height;
    if (style == BorderStyle.double_)
    {
        const m = width.top > width.bottom ? width.top : width.bottom;
        const n = width.left > width.right ? width.left : width.right;
        const t = (m > n ? m : n) * unit;
        HalfRect[8] e;
        if (insetY2 > 0)
        {
            const s2 = 3 * t; // 1.5t
            e[0 .. 4] = halfEdges(x2 - s2, y2 - s2, w2 + 2 * s2, h2 + 2 * s2, width,
                unit, inset2, insetY2);
            e[4 .. 8] = halfEdges(x2 + s2, y2 + s2, w2 - 2 * s2, h2 - 2 * s2, width,
                unit, inset2, insetY2);
        }
        else
        {
            const g2 = 4 * t; // 2t
            e[0 .. 4] = halfEdges(x2, y2, w2, h2, width, unit, inset2, 0);
            e[4 .. 8] = halfEdges(x2, y2 + g2, w2, h2 - 2 * g2, width, unit, inset2, 0);
        }
        foreach (ref const edge; e)
            strokeHalf(edge, BorderStyle.solid, sink);
        return;
    }
    foreach (ref const edge; halfEdges(x2, y2, w2, h2, width, unit, inset2, insetY2))
        strokeHalf(edge, style, sink);
}

/// The pixels of one border stroke, as $(LREF borderRects) truncates them.
private void strokeHalf(Sink)(in HalfRect e, BorderStyle style, scope Sink sink)
{
    if (e.w2 <= 0 || e.h2 <= 0)
        return;
    if (style != BorderStyle.dotted && style != BorderStyle.dashed)
        return emit(e.x2, e.y2, e.w2, e.h2, sink);
    const horizontal = e.w2 >= e.h2;
    const thick2 = horizontal ? e.h2 : e.w2;
    const len2 = horizontal ? e.w2 : e.h2;
    const dash2 = style == BorderStyle.dotted ? thick2 : thick2 * 3;
    const gap2 = style == BorderStyle.dotted ? thick2 : thick2 * 2;
    for (int p2 = 0; p2 < len2; p2 += dash2 + gap2)
    {
        const seg2 = p2 + dash2 <= len2 ? dash2 : len2 - p2;
        if (horizontal)
            emit(e.x2 + p2, e.y2, seg2, thick2, sink);
        else
            emit(e.x2, e.y2 + p2, thick2, seg2, sink);
    }
}

// Each half-pixel component truncated on its own; nothing for an empty one.
private void emit(Sink)(int x2, int y2, int w2, int h2, scope Sink sink)
{
    const r = Rect(x2 / 2, y2 / 2, w2 / 2, h2 / 2);
    if (!r.empty)
        sink(r);
}

// A rectangle in half pixels.
private struct HalfRect
{
    int x2, y2, w2, h2;
}

/*
The four edges of a square border in half pixels: top, bottom, left, right.
`inset2` centres a vertical stroke that far into its column; `insetY2`, when
positive, centres the horizontals in their rows and makes each stroke end at
the outer face of the one it meets.
*/
private HalfRect[4] halfEdges(int x2, int y2, int w2, int h2, in Insets width, int unit,
    int inset2, int insetY2) @safe pure nothrow @nogc
{
    // Thicknesses in pixels, which are also their halves in half pixels.
    const t = width.top * unit, b = width.bottom * unit;
    const l = width.left * unit, r = width.right * unit;
    const corner = insetY2 > 0;
    const cxL = x2 + inset2, cxR = x2 + w2 - inset2;
    const cyT = y2 + insetY2, cyB = y2 + h2 - insetY2;
    const hx0 = corner && width.left ? cxL - l : x2;
    const hx1 = corner && width.right ? cxR + r : x2 + w2;
    const vy0 = corner && width.top ? cyT - t : y2;
    const vy1 = corner && width.bottom ? cyB + b : y2 + h2;
    return [
        HalfRect(hx0, corner ? cyT - t : y2, hx1 - hx0, 2 * t),
        HalfRect(hx0, corner ? cyB - b : y2 + h2 - 2 * b, hx1 - hx0, 2 * b),
        HalfRect(width.left ? cxL - l : x2, vy0, 2 * l, vy1 - vy0),
        HalfRect(width.right ? cxR - r : x2 + w2 - 2 * r, vy0, 2 * r, vy1 - vy0),
    ];
}

version (unittest)
{
    // Every rect `borderRects` emits, in order.
    private struct Collected
    {
        Rect[256] rects;
        size_t length;

        void opCall(Rect r) @safe pure nothrow @nogc
        {
            rects[length++] = r;
        }

        const(Rect)[] opSlice() const return @safe pure nothrow @nogc => rects[0 .. length];

        bool are(scope const(Rect)[] want...) const @safe pure nothrow @nogc
            => rects[0 .. length] == want;
    }

    private Collected borderOf(in Rect box, in Insets width, BorderStyle style,
        int cellW, int cellH) @safe pure nothrow @nogc
    {
        Collected c;
        borderRects(box, width, style, cellW, cellH, (Rect r) { c(r); });
        return c;
    }
}

///
@("pixelGeometry.borderRects.solidBoxMeetsAtBoxDrawingCorners")
@safe pure nothrow @nogc
unittest
{
    // 13 × 3 cells of 10 × 20: strokes centred in their rows and columns,
    // each corner a meeting of two arms.
    const c = borderOf(Rect(0, 0, 130, 60), Insets.all(1), BorderStyle.solid, 10, 20);
    assert(c.are(Rect(4, 9, 121, 1), Rect(4, 49, 121, 1), Rect(4, 9, 1, 41),
        Rect(124, 9, 1, 41)));
}

///
@("pixelGeometry.borderRects.oddCellsTruncateHalfPixels")
@safe pure nothrow @nogc
unittest
{
    // A 9 px column centres its stroke at 4.5: the stroke spans [4, 5).
    const c = borderOf(Rect(0, 0, 90, 34), Insets(0, 0, 0, 1), BorderStyle.solid, 9, 17);
    assert(c.are(Rect(4, 0, 1, 34)), "a left side alone, centred in its column");
}

///
@("pixelGeometry.borderRects.dropsAbsentSides")
@safe pure nothrow @nogc
unittest
{
    const bottom = borderOf(Rect(0, 0, 40, 20), Insets(0, 0, 1, 0), BorderStyle.solid, 10, 20);
    assert(bottom.are(Rect(0, 19, 40, 1)), "a bottom rule keeps the box's edge");
    const accent = borderOf(Rect(0, 0, 40, 20), Insets(0, 0, 0, 3), BorderStyle.dotted, 10, 20);
    assert(accent.length == 4 && accent[][0] == Rect(-1, 0, 3, 3),
        "a dotted left accent straddles the edge, as dots down it");
    assert(borderOf(Rect(0, 0, 40, 20), Insets.all(1), BorderStyle.none, 10, 20).length == 0);
}

///
@("pixelGeometry.borderRects.dashesRunAlongTheirEdge")
@safe pure nothrow @nogc
unittest
{
    // Dashed, weight 1, 1 px unit: 3 px dashes with 2 px gaps.
    const c = borderOf(Rect(0, 0, 12, 20), Insets(1, 0, 0, 0), BorderStyle.dashed, 10, 20);
    assert(c.are(Rect(0, 0, 3, 1), Rect(5, 0, 3, 1), Rect(10, 0, 2, 1)),
        "the last dash cut at the edge's end");
    const d = borderOf(Rect(0, 0, 10, 5), Insets(0, 1, 0, 0), BorderStyle.dotted, 10, 20);
    assert(d.are(Rect(9, 0, 1, 1), Rect(9, 2, 1, 1), Rect(9, 4, 1, 1)),
        "a vertical edge dots down its own axis");
}

///
@("pixelGeometry.borderRects.doubleNestsTwoBoxes")
@safe pure nothrow @nogc
unittest
{
    const c = borderOf(Rect(0, 0, 130, 60), Insets.all(1), BorderStyle.double_, 10, 20);
    assert(c.length == 8);
    const outer = c[][0 .. 4], inner = c[][4 .. 8];
    assert(outer[0] == Rect(3, 8, 124, 1) && inner[0] == Rect(6, 11, 118, 1),
        "top: either side of the row's centre, a 2 px gap between");
    assert(outer[2] == Rect(3, 8, 1, 44) && inner[2] == Rect(6, 11, 1, 38));

    const rule = borderOf(Rect(0, 0, 40, 20), Insets(0, 0, 1, 0), BorderStyle.double_, 10, 20);
    assert(rule.are(Rect(0, 19, 40, 1), Rect(0, 17, 40, 1)),
        "without a side, the second stroke steps inward");
}

///
@("pixelGeometry.borderRects.heavyStrokesScaleByTheUnit")
@safe pure nothrow @nogc
unittest
{
    assert(borderUnit(10, 20) == 1 && borderUnit(28, 40) == 2 && borderUnit(5, 9) == 1);
    const c = borderOf(Rect(0, 0, 280, 120), Insets.all(2), BorderStyle.solid, 28, 40);
    // Weight 2 at a 2 px unit: 4 px strokes centred 14 px into the columns.
    assert(c[][2] == Rect(12, 18, 4, 84) && c[][0] == Rect(12, 18, 256, 4));
}

///
@("pixelGeometry.borderRects.stayNearTheirBox")
@safe pure nothrow @nogc
unittest
{
    // The defect `borderEdges` was extracted for, as a property: an edge
    // never runs a box length past its box.
    const box = Rect(100, 40, 130, 78);
    foreach (r; borderOf(box, Insets.all(1), BorderStyle.dotted, 10, 20)[])
    {
        assert(r.x >= box.x - r.width && r.right <= box.right + r.width);
        assert(r.y >= box.y - r.height && r.bottom <= box.bottom + r.height);
    }
    foreach (r; borderOf(Rect(0, 0, 2, 2), Insets.all(5), BorderStyle.solid, 10, 20)[])
        assert(!r.empty, "nothing empty is emitted");
}

/// The stroke thickness of a rounded box's outline: its thickest side, at
/// least 1, in CSS pixels times `density`. A rounded outline is uniform, and
/// drawn with coverage rather than as pixel rectangles.
float roundedBorderPx(in Insets width, float density) @safe pure nothrow @nogc
{
    int m = width.top;
    if (width.right > m)
        m = width.right;
    if (width.bottom > m)
        m = width.bottom;
    if (width.left > m)
        m = width.left;
    return (m <= 0 ? 1 : m) * density;
}

/// The radius a rounded box of `w`×`h` pixels draws with for a corner radius of
/// `radius` pixels: at most half its shorter side.
float cornerRadiusPx(int radius, float w, float h) @safe pure nothrow @nogc
{
    const half = (w < h ? w : h) / 2.0f;
    if (half <= 0 || radius <= 0)
        return 0;
    return radius < half ? radius : half;
}

///
@("pixelGeometry.cornerRadiusPx.clampsToHalfTheShorterSide")
@safe pure nothrow @nogc
unittest
{
    assert(cornerRadiusPx(12, 100, 40) == 12);
    assert(cornerRadiusPx(44, 100, 40) == 20, "a pill");
    assert(cornerRadiusPx(0, 100, 40) == 0);
    assert(roundedBorderPx(Insets(1, 2, 1, 1), 2.0f) == 4);
    assert(roundedBorderPx(Insets.init, 1.5f) == 1.5f);
}

// ---------------------------------------------------------------------------
// Shadows and arrows
// ---------------------------------------------------------------------------

/**
The rectangle a box's drop shadow fills: `box` moved by the shadow's offset,
widened by its blur — `⌈blur/2⌉` pixels to the left and `⌊blur/2⌋` to the
right — and lengthened downward by `⌈blur/2⌉`. No blur kernel runs: the blur
radius only grows the shape, which keeps the box's corner radius. A negative
blur counts as none.

These are the pixels the reference canvas filled when it drew the shadow as
the half-pixel rectangle `(x + dx − blur/2, y + dy, w + blur, h + blur/2)`:
its rasterizer, with y pointing down the window, rounds a half-pixel left
edge down and a half-pixel bottom edge up.
*/
Rect shadowRect(in Rect box, in Shadow s) @safe pure nothrow @nogc
{
    const blur = s.blur > 0 ? s.blur : 0;
    const half = (blur + 1) / 2;
    return Rect(box.x + s.dx - half, box.y + s.dy, box.width + blur, box.height + half);
}

///
@("pixelGeometry.shadowRect.growsByTheBlurDownAndAcross")
@safe pure nothrow @nogc
unittest
{
    const box = Rect(10, 20, 40, 30);
    assert(shadowRect(box, Shadow(dx: 0, dy: 4, blur: 12)) == Rect(4, 24, 52, 36));
    assert(shadowRect(box, Shadow(dx: 2, dy: 2, blur: 3)) == Rect(10, 22, 43, 32),
        "an odd blur: the larger half to the left and below");
    assert(shadowRect(Rect(0, 0, 10, 10), Shadow(dx: -3, blur: 5)) == Rect(-6, 0, 15, 13));
    assert(shadowRect(box, Shadow.init) == box);
    assert(shadowRect(box, Shadow(blur: -4)) == box);
}

/// The popup arrow's triangle, in device pixels: its apex and its base's left
/// and right ends.
struct ArrowTriangle
{
    float[2] apex;  ///
    float[2] left;  ///
    float[2] right; ///
}

/**
The arrow off a popup's top edge: a triangle whose base, one pixel into the
box so it merges with the surface, centres on the middle of cell column
`arrowOffset`, a third of a cell tall (at least 4 pixels) and twice that wide.
*/
ArrowTriangle arrowTriangle(int boxX, int boxY, int arrowOffset, int cellW, int cellH) @safe pure nothrow @nogc
{
    const size = cellH / 3 < 4 ? 4.0f : cast(float)(cellH / 3);
    const cx = boxX + arrowOffset * cellW + cellW * 0.5f;
    return ArrowTriangle([cx, boxY - size], [cx - size, boxY + 1.0f], [cx + size, boxY + 1.0f]);
}

///
@("pixelGeometry.arrowTriangle")
@safe pure nothrow @nogc
unittest
{
    const a = arrowTriangle(100, 50, 2, 10, 21);
    assert(a.apex == [125.0f, 43.0f] && a.left == [118.0f, 51.0f] && a.right == [132.0f, 51.0f]);
    assert(arrowTriangle(0, 10, 0, 8, 9).apex == [4.0f, 6.0f], "at least 4 px");
}

// ---------------------------------------------------------------------------
// Scrollbars
// ---------------------------------------------------------------------------

/// The idle scrollbar rail thickness for a cell extent, in device pixels.
int railIdlePx(int cellExtent) @safe pure nothrow @nogc
{
    const third = cellExtent / 3;
    return third < 2 ? 2 : third;
}

/// The fully-expanded scrollbar rail thickness: exactly 1.5 glyph-cell widths,
/// including odd widths (integer multiply before divide is normative). Both
/// axes use the width so horizontal rails retain their compact GUI height.
int railExpandedPx(int cellWidth) @safe pure nothrow @nogc => cellWidth * 3 / 2;

/// The pixel backend's minimum grabbable scrollbar-handle length.
enum int scrollbarMinExtentPx = 24;

/// Pure, window-free resolved pixel geometry for one semantic scrollbar op.
struct ScrollbarRail
{
    Rect track; ///
    Rect thumb; ///
    bool live;  ///
}

/**
Resolves a semantic scrollbar operation into pixel track/thumb geometry. The
op keeps content units and an expansion percentage; the pixel canvases alone
choose the rail's thickness and the 24px minimum grabbable thumb.
*/
ScrollbarRail scrollbarRail(in Scrollbar op, int cellW, int cellH,
    int originX = 0, int originY = 0, int minExtent = scrollbarMinExtentPx) @safe pure nothrow @nogc
{
    if (op.fadePercent == 0)
        return ScrollbarRail.init;
    bool vertical;
    final switch (op.edge) with (RuleEdge)
    {
        case left: case right: case centerX:
            vertical = true;
            break;
        case top: case bottom: case centerY:
            vertical = false;
            break;
    }
    const idle = railIdlePx(vertical ? cellW : cellH);
    const expanded = railExpandedPx(cellW);
    const thickness = idle + (expanded - idle) * cast(int) op.expandPercent / 100;
    return scrollbarRailPx(Rect(originX + op.rect.x * cellW,
            originY + op.rect.y * cellH, op.rect.width * cellW,
            op.rect.height * cellH),
        op.edge, op.content, op.viewport, op.offset, op.offsetFrac, thickness,
        minExtent);
}

/**
The same resolution for a band given in pixels — a terminal pane's padding,
which is not a whole number of cells — at a `thickness` the caller resolved:
the one geometry every bar paints and hit-tests with (`SCV13`).
`offsetFrac` is the view's fraction past `offset` in 256ths, so the thumb
slides with content scrolled between cells (`LAY7`).
*/
ScrollbarRail scrollbarRailPx(in Rect band, RuleEdge edge, long content,
    long viewport, long offset, ubyte offsetFrac, int thickness,
    int minExtent = scrollbarMinExtentPx) @safe pure nothrow @nogc
{
    ScrollbarRail r;
    if (content <= viewport || content <= 0)
        return r;
    const x = band.x, y = band.y, w = band.width, h = band.height;
    bool vertical;
    final switch (edge) with (RuleEdge)
    {
        case left:
            r.track = Rect(x, y, thickness, h);
            vertical = true;
            break;
        case right:
            r.track = Rect(x + w - thickness, y, thickness, h);
            vertical = true;
            break;
        case centerX:
            r.track = Rect(x + w / 2 - thickness / 2, y, thickness, h);
            vertical = true;
            break;
        case top:
            r.track = Rect(x, y, w, thickness);
            break;
        case bottom:
            r.track = Rect(x, y + h - thickness, w, thickness);
            break;
        case centerY:
            r.track = Rect(x, y + h / 2 - thickness / 2, w, thickness);
            break;
    }

    const track = vertical ? h : w;
    if (track <= 0 || thickness <= 0)
        return ScrollbarRail.init;
    // In 256ths of a unit, so a fraction moves the thumb by the pixels it
    // should rather than by none until a whole unit is crossed.
    const thumb = scrollbarThumb(content * 256, viewport * 256,
        offset * 256 + offsetFrac, track, minExtent);
    r.thumb = vertical
        ? Rect(r.track.x, y + thumb.start, thickness, thumb.extent)
        : Rect(x + thumb.start, r.track.y, thumb.extent, thickness);
    r.live = true;
    return r;
}

@("pixelGeometry.scrollbarRail.aLongHistoryKeepsAThumbAFingerCanTake")
@safe pure nothrow @nogc
unittest
{
    // `seq 1 100000` in a 40-row pane on a 2000 px track: proportionally a
    // thumb under a pixel; the minimum keeps it 132 px (48 dp at 2.75×), and
    // the newest rows still put it flush with the track's end.
    const band = Rect(0, 0, 24, 2000);
    const top = scrollbarRailPx(band, RuleEdge.right, 100_040, 40, 0, 0, 8, 132);
    const end = scrollbarRailPx(band, RuleEdge.right, 100_040, 40, 100_000, 0, 8, 132);
    assert(top.thumb.height == 132 && top.thumb.y == 0);
    assert(end.thumb.y + end.thumb.height == 2000, "the newest rows: at the bottom");
}

@("pixelGeometry.scrollbarRail.aFractionSlidesTheThumb")
@safe pure nothrow @nogc
unittest
{
    const band = Rect(0, 0, 12, 400);
    const at = scrollbarRailPx(band, RuleEdge.right, 100, 10, 45, 0, 4);
    const half = scrollbarRailPx(band, RuleEdge.right, 100, 10, 45, 128, 4);
    assert(at.live && at.thumb.height == 40 && at.thumb.y == 180);
    assert(half.thumb.y == 182);
    assert(half.track == Rect(8, 0, 4, 400), "on the band's right edge");
    Scrollbar faded;
    faded.rect = Rect(0, 0, 1, 10);
    faded.content = 100;
    faded.viewport = 10;
    faded.fadePercent = 0;
    assert(!scrollbarRail(faded, 8, 16).live, "a faded-out bar paints nothing");
}

@("pixelGeometry.scrollbarRail.metricsAndOddCells")
@safe pure nothrow @nogc
unittest
{
    assert(railIdlePx(5) == 2);
    assert(railIdlePx(21) == 7);
    assert(railExpandedPx(5) == 7);  // not cast(int)(5 * 1.5f) by accident
    assert(railExpandedPx(21) == 31);

    Scrollbar op = {
        rect: Rect(2, 1, 10, 20),
        content: 400,
        viewport: 100,
        expandPercent: 0,
        edge: RuleEdge.right,
    };
    const idle = scrollbarRail(op, 5, 7);
    assert(idle.live && idle.track == Rect(58, 7, 2, 140));
    assert(idle.thumb == Rect(58, 7, 2, 35));

    op.expandPercent = 100;
    const expanded = scrollbarRail(op, 5, 7);
    assert(expanded.track == Rect(53, 7, 7, 140));
    op.expandPercent = 50;
    const middle = scrollbarRail(op, 5, 7);
    assert(middle.track.width >= idle.track.width);
    assert(middle.track.width <= expanded.track.width);

    op.offset = 300;
    const bottom = scrollbarRail(op, 5, 7);
    assert(bottom.thumb.y + bottom.thumb.height
        == bottom.track.y + bottom.track.height);

    op.edge = RuleEdge.bottom;
    op.rect = Rect(1, 2, 20, 3);
    op.content = 200;
    op.viewport = 100;
    op.offset = 100;
    op.expandPercent = 100;
    const horizontal = scrollbarRail(op, 5, 7);
    assert(horizontal.track.height == railExpandedPx(5));
    assert(horizontal.thumb.x + horizontal.thumb.width
        == horizontal.track.x + horizontal.track.width);

    // Horizontal bars historically expand to 1.5 glyph widths, not 1.5 row
    // heights. The distinction is substantial for a typical tall font cell.
    const compactHorizontal = scrollbarRail(op, 9, 21);
    assert(compactHorizontal.track.height == 13);
}

// ---------------------------------------------------------------------------
// Clips
// ---------------------------------------------------------------------------

/// The device-pixel scissor rectangle a clip resolves to.
struct ScissorBox
{
    int x, y, w, h; ///
}

/// A pushed clip and the sub-cell shift, in pixels, in force when it was
/// pushed (`LAY7`).
struct ClipEntry
{
    Rect rect;     /// in cells
    int shiftX;    ///
    int shiftY;    ///
}

/**
Turns a clip rect in cells into a device-pixel scissor box, clamped to a
target `boundW` x `boundH`. Returns `false` when nothing survives.

$(B The clamp is where this went wrong.) An axis-only viewport (`clipX`
without `clipY`) leaves the other axis spanning the whole `int` range, so the
bound is doing real work rather than tidying edges — and the bound must be the
size of the target actually being drawn into, which inside an `EFX11` bracket
is a texture rather than the screen. An earlier `cast(float) int.max`
"unbounded" sentinel rounded up to 2147483648.0f, came back as `int.min`, and
handed GL a negative width. Integer throughout, and a real bound, is the fix.
*/
bool scissorBoxOf(in Rect clip, int originX, int originY,
    int cellW, int cellH, int boundW, int boundH, out ScissorBox box) @safe pure nothrow @nogc
{
    if (clip.empty || boundW <= 0 || boundH <= 0)
        return false;

    static long cl(long v, long lo, long hi)
        => v < lo ? lo : (v > hi ? hi : v);

    // `long` throughout: a sentinel cell coordinate times a cell size
    // overflows `int` long before it reaches the clamp.
    const ox = cast(long) originX, oy = cast(long) originY;
    const x0 = cl(ox + cast(long) clip.x * cellW, 0, boundW);
    const y0 = cl(oy + cast(long) clip.y * cellH, 0, boundH);
    const x1 = cl(ox + (cast(long) clip.x + clip.width) * cellW, 0, boundW);
    const y1 = cl(oy + (cast(long) clip.y + clip.height) * cellH, 0, boundH);
    if (x1 <= x0 || y1 <= y0)
        return false;

    box = ScissorBox(cast(int) x0, cast(int) y0,
        cast(int)(x1 - x0), cast(int)(y1 - y0));
    return true;
}

/**
The device-pixel scissor a stack of clips resolves to: each clip turned into
pixels at the origin it was pushed under — `baseX`/`baseY` is the origin with
no shift open, and each entry adds the shift that was — then intersected.
A clip pushed outside a viewport's shift stays where the viewport is; one
pushed inside it moves with the content (`LAY7`).
*/
bool scissorBoxOfStack(scope const(ClipEntry)[] clips, int baseX, int baseY,
    int cellW, int cellH, int boundW, int boundH, out ScissorBox box) @safe pure nothrow @nogc
{
    if (!clips.length)
        return false;
    int x0 = 0, y0 = 0, x1 = int.max, y1 = int.max;
    foreach (ref const c; clips)
    {
        ScissorBox b;
        if (!scissorBoxOf(c.rect, baseX + c.shiftX, baseY + c.shiftY, cellW, cellH,
                boundW, boundH, b))
            return false;
        x0 = b.x > x0 ? b.x : x0;
        y0 = b.y > y0 ? b.y : y0;
        x1 = b.x + b.w < x1 ? b.x + b.w : x1;
        y1 = b.y + b.h < y1 ? b.y + b.h : y1;
    }
    if (x1 <= x0 || y1 <= y0)
        return false;
    box = ScissorBox(x0, y0, x1 - x0, y1 - y0);
    return true;
}

@("pixelGeometry.scissorBoxOfStack.aShiftMovesTheContentNotTheViewportClip")
@safe pure nothrow @nogc
unittest
{
    // 10×20 px cells. A viewport clip at rows 1..5, then a half-row shift
    // (−10 px), then a nested clip (a code block) at rows 2..4 of the content.
    ClipEntry[2] stack = [ClipEntry(Rect(0, 1, 30, 4)),
        ClipEntry(Rect(0, 2, 30, 2), 0, -10)];
    ScissorBox box;
    assert(scissorBoxOfStack(stack[0 .. 1], 0, 0, 10, 20, 800, 600, box));
    assert(box == ScissorBox(0, 20, 300, 80), "the viewport's own clip ignores the shift");
    assert(scissorBoxOfStack(stack[], 0, 0, 10, 20, 800, 600, box));
    assert(box == ScissorBox(0, 30, 300, 40), "the nested clip moves with the content");
    assert(!scissorBoxOfStack(null, 0, 0, 10, 20, 800, 600, box));
}

@("pixelGeometry.scissorBoxOf.clampsToTheTargetNotToASentinel")
@safe pure nothrow @nogc
unittest
{
    ScissorBox box;

    // The ordinary case: a viewport well inside the target.
    assert(scissorBoxOf(Rect(2, 1, 10, 4), 0, 0, 10, 24, 800, 600, box));
    assert(box == ScissorBox(20, 24, 100, 96));

    // `LAY7`'s axis-only viewport: one axis spans the whole int range, and
    // the bound is what makes that expressible at all. The regression this
    // guards produced a NEGATIVE width here.
    const wide = Rect(-1_073_741_824, 1, 2_147_483_647, 31);
    assert(scissorBoxOf(wide, -250, -408, 10, 24, 340, 96, box));
    assert(box.x >= 0 && box.y >= 0);
    assert(box.w > 0 && box.h > 0, "a negative extent is GL_INVALID_VALUE");
    assert(box.x + box.w <= 340 && box.y + box.h <= 96,
        "never larger than the target being drawn into");
    assert(box == ScissorBox(0, 0, 340, 96), "the bracket is fully visible");

    // Inside an effect bracket the origin is shifted so the bracket's own
    // cell lands at the target's (0, 0); a clip that starts above it clamps
    // rather than going negative.
    assert(scissorBoxOf(Rect(0, 0, 100, 100), -250, -408, 10, 24, 340, 96, box));
    assert(box == ScissorBox(0, 0, 340, 96));

    // Fully off the target, and degenerate inputs, report nothing rather
    // than a box GL would reject.
    assert(!scissorBoxOf(Rect(100, 100, 2, 2), 0, 0, 10, 24, 340, 96, box));
    assert(!scissorBoxOf(Rect(0, 0, 0, 0), 0, 0, 10, 24, 340, 96, box));
    assert(!scissorBoxOf(Rect(0, 0, 4, 4), 0, 0, 10, 24, 0, 0, box));
}
