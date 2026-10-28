/**
The generated box-drawing face (`docs/specs/font/discovery.md` § 6,
FTD35–FTD38).

A fallback chain draws U+2500–U+259F from a face generated for the primary
face's cell rather than from whatever font happens to cover them, so lines
join across cells and blocks fill them exactly. The face is a real TrueType
font — `head`, `hhea`, `maxp` 1.0, `OS/2` 4, `hmtx`, `cmap` format 4 (3/1),
`loca` (long), `glyf`, `name` and `post` 3.0 — so it opens with `openFace`
and every reader, the rasterizer and the shaper treat it like any other.

Its units per em are `ppem · k`, `k` the largest power of two at most 64
with `ppem · k ≤ 16,384`, so one pixel is exactly `k` units and every
pixel-aligned edge stays pixel-aligned at the cell's ppem. All geometry is
computed in pixels from the cell's top-left corner (FTD37) and turned into
font units as `x · k` and `(baseline − y) · k`.

The bytes go into the caller's storage, sized by `boxFaceMeasure` (the
library's measure-then-fill idiom); nothing allocates. Building the face
costs O(w · h) for a cell of `w` by `h` pixels: the shades hold one square
per `u`-pixel block, at most 3,072 per glyph.

$(UL
    $(LI `boxFaceFamily` and `boxFaceCoverage`: the family and the scalars
        of FTD35 and FTD38.)
    $(LI `boxFaceMeasure`: the layout and byte length for a cell.)
    $(LI `buildBoxFace`: the font's bytes into caller storage.)
)
*/
module sparkles.font.box_face;

import sparkles.font.cmap : CodepointRange;
import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontLimit, FontResult,
    fontErr, fontOk;
import sparkles.font.metrics : CellMetrics;

import std.math : floor;

@safe pure nothrow @nogc:

/// The family name of the box-drawing face (FTD38).
enum string boxFaceFamily = "Sparkles Box Drawing";

/// The largest ppem the face can be built at: `ppem · k ≤ 16,384` with `k ≥ 1` (FTD36).
enum uint boxFaceMaxPpem = 16_384;

/// The scalars the face covers, in ascending order (FTD35).
immutable CodepointRange[2] boxFaceRanges = [CodepointRange(0x20, 0x20), CodepointRange(0x2500, 0x259F)];

/// The scalars the face covers: U+0020 and U+2500–U+259F (FTD35).
const(CodepointRange)[] boxFaceCoverage() => boxFaceRanges[];

/// The glyph count: `.notdef`, the space and one glyph per U+2500–U+259F.
enum uint boxFaceGlyphCount = 2 + 0xA0;

/// What a face built for one cell looks like, before its bytes are written.
struct BoxFaceLayout
{
    @safe pure nothrow @nogc:

    /// The font's length in bytes: the storage `buildBoxFace` needs.
    size_t length;
    /// `head.unitsPerEm`: `ppem · unitsPerPixel`.
    uint unitsPerEm;
    /// `k`: font units per pixel at the cell's ppem.
    uint unitsPerPixel;
    /// The light stroke `t` in pixels (FTD37).
    uint lightStroke;
}

/**
The layout of the box-drawing face for `cell` (FTD36): the byte length its
storage needs, its units per em and its light stroke. It runs the whole
build without writing, so it costs as much as `buildBoxFace`.

A ppem of zero, a width or height below 1, a baseline outside the cell, or
an underline thicker than the cell is `badValue`; a ppem above 16,384, or a
cell whose outline coordinates do not fit the 16-bit `glyf` fields, is
`limitExceeded`.
*/
FontResult!BoxFaceLayout boxFaceMeasure(in CellMetrics cell)
{
    const g = geometryOf(cell);
    if (g.hasError)
        return fontErr!BoxFaceLayout(g.error);
    Out counter;
    const written = writeFont(counter, g.value);
    if (written.hasError)
        return fontErr!BoxFaceLayout(written.error);
    return fontOk(BoxFaceLayout(counter.at, cell.ppem * g.value.k, g.value.k, g.value.t));
}

/**
Writes the box-drawing face for `cell` into `storage` and returns the
written prefix, which `openFace` opens (FTD36). Table checksums and
`head.checkSumAdjustment` are set. The errors are `boxFaceMeasure`'s, and
a `storage` shorter than its `length` is `limitExceeded` naming
`callerStorage` with that length; nothing is written then.
*/
FontResult!(ubyte[]) buildBoxFace(in CellMetrics cell, return scope ubyte[] storage)
{
    const layout = boxFaceMeasure(cell);
    if (layout.hasError)
        return fontErr!(ubyte[])(layout.error);
    const length = layout.value.length;
    if (storage.length < length)
        return fontErr!(ubyte[])(callerStorageError(length));
    Out o;
    o.buf = storage[0 .. length];
    o.writing = true;
    const written = writeFont(o, geometryOf(cell).value);
    assert(written.hasValue && o.at == length, "the writing pass follows the counting pass");
    return fontOk(storage[0 .. length]);
}

///
@("box_face.buildBoxFace.sizeAndErrors")
@safe pure nothrow
unittest
{
    CellMetrics cell;
    cell.ppem = 16;
    cell.width = 8;
    cell.height = 16;
    cell.baseline = 12;
    const layout = boxFaceMeasure(cell);
    assert(layout.hasValue && layout.value.unitsPerEm == 1_024 && layout.value.unitsPerPixel == 64);
    ubyte[32_768] storage;
    assert(layout.value.length <= storage.length);
    const bytes = buildBoxFace(cell, storage);
    assert(bytes.hasValue && bytes.value.length == layout.value.length);
    assert(bytes.value[0 .. 4] == [0, 1, 0, 0]);

    const short_ = buildBoxFace(cell, storage[0 .. 10]);
    assert(short_.hasError && short_.error.limit == FontLimit.callerStorage
        && short_.error.needed == layout.value.length);
    cell.ppem = boxFaceMaxPpem + 1;
    assert(boxFaceMeasure(cell).error.kind == FontErrorKind.limitExceeded);
    cell.ppem = 0;
    assert(boxFaceMeasure(cell).error.kind == FontErrorKind.badValue);
}

// ---------------------------------------------------------------------------
// The cell
// ---------------------------------------------------------------------------

/// The cell in pixels, and `k` units per pixel.
private struct Geometry
{
    @safe pure nothrow @nogc:

    int w, h, baseline, k, t;
    uint ppem;
    /// The post table's underline, in font units.
    int underlinePosition, underlineThickness;
}

private enum int maxUnit = short.max;

private FontResult!Geometry geometryOf(in CellMetrics cell)
{
    if (cell.ppem == 0)
        return fontErr!Geometry(FontError(FontErrorKind.badValue));
    if (cell.ppem > boxFaceMaxPpem)
        return fontErr!Geometry(FontError(FontErrorKind.limitExceeded));
    if (cell.width < 1 || cell.height < 1 || cell.baseline < 0 || cell.baseline > cell.height)
        return fontErr!Geometry(FontError(FontErrorKind.badValue));
    if (cell.width > maxUnit || cell.height > maxUnit)
        return fontErr!Geometry(FontError(FontErrorKind.limitExceeded));
    int k = 64;
    while (k > 1 && cell.ppem * k > boxFaceMaxPpem)
        k /= 2;
    Geometry g;
    g.ppem = cell.ppem;
    g.w = cast(int) cell.width;
    g.h = cast(int) cell.height;
    g.baseline = cast(int) cell.baseline;
    g.k = k;
    if (long(g.w) * k > maxUnit || long(g.h) * k > maxUnit)
        return fontErr!Geometry(FontError(FontErrorKind.limitExceeded));
    // `round(underlineThickness)`: the metric is already whole pixels.
    const thickness = cell.hasUnderline ? cell.underlineThickness : 1;
    if (thickness > (g.w > g.h ? g.w : g.h))
        return fontErr!Geometry(FontError(FontErrorKind.badValue));
    g.t = thickness < 1 ? 1 : cast(int) thickness;
    if (cell.hasUnderline)
    {
        const position = (long(g.baseline) - cell.underlinePosition) * k;
        if (position < short.min || position > short.max)
            return fontErr!Geometry(FontError(FontErrorKind.limitExceeded));
        g.underlinePosition = cast(int) position;
        g.underlineThickness = g.t * k;
    }
    return fontOk(g);
}

/// `⌊a / b⌋` for `b > 0`, rounding toward negative infinity.
private int floorDiv(int a, int b) => a >= 0 ? a / b : -((-a + b - 1) / b);

/// A half-open pixel interval.
private struct Span
{
    int lo, hi;
}

/// A stroke `s` wide centred across `extent` pixels (FTD37).
private Span stroke(int extent, int s)
{
    const lo = floorDiv(extent - s, 2);
    return Span(lo, lo + s);
}

// ---------------------------------------------------------------------------
// Outline output
// ---------------------------------------------------------------------------

/// An outline point in font units, y up.
private struct Pt
{
    int x, y;
    bool on = true;
}

/// The most points one generated contour holds (an arc: ten).
private enum maxContourPoints = 16;

/// One contour under construction, in pixel-frame units (y down from the cell top).
private struct Contour
{
    @safe pure nothrow @nogc:

    Pt[maxContourPoints] pts;
    uint n;

    /// Appends a point, dropping one equal to the previous.
    void add(int x, int y, bool on = true)
    {
        if (n > 0 && pts[n - 1].x == x && pts[n - 1].y == y && pts[n - 1].on == on)
            return;
        assert(n < maxContourPoints);
        pts[n++] = Pt(x, y, on);
    }
}

/**
Hands `c` to `sink` in font units, clockwise as TrueType draws outer
contours: y flips to `(baseline · k) − y`, and a contour whose signed area
is counterclockwise is reversed.
*/
private void emit(Sink)(in Geometry g, ref Sink sink, ref Contour c)
{
    auto n = c.n;
    // The closing point may repeat the first.
    if (n > 1 && c.pts[n - 1] == c.pts[0])
        --n;
    if (n < 3)
        return;
    Pt[maxContourPoints] out_;
    long area2;
    foreach (i; 0 .. n)
        out_[i] = Pt(c.pts[i].x, g.baseline * g.k - c.pts[i].y, c.pts[i].on);
    foreach (i; 0 .. n)
    {
        const a = out_[i], b = out_[(i + 1) % n];
        area2 += long(a.x) * b.y - long(b.x) * a.y;
    }
    if (area2 > 0) // counterclockwise with y up
        foreach (i; 0 .. n / 2)
        {
            const tmp = out_[i];
            out_[i] = out_[n - 1 - i];
            out_[n - 1 - i] = tmp;
        }
    sink.contour(out_[0 .. n]);
}

/// A pixel rectangle `[x0, x1) × [y0, y1)`, y down.
private struct Rect
{
    int x0, y0, x1, y1;

    bool empty() const @safe pure nothrow @nogc => x0 >= x1 || y0 >= y1;
}

/// Emits the pixel rectangle `r`.
private void emitRect(Sink)(in Geometry g, ref Sink sink, Rect r)
{
    if (r.empty)
        return;
    Contour c;
    c.add(r.x0 * g.k, r.y0 * g.k);
    c.add(r.x1 * g.k, r.y0 * g.k);
    c.add(r.x1 * g.k, r.y1 * g.k);
    c.add(r.x0 * g.k, r.y1 * g.k);
    emit(g, sink, c);
}

/// Whether two of `rects` share area, so the glyph needs `OVERLAP_SIMPLE`.
private bool anyOverlap(scope const(Rect)[] rects)
{
    foreach (i, a; rects)
        foreach (b; rects[i + 1 .. $])
            if (!a.empty && !b.empty && a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1)
                return true;
    return false;
}

// ---------------------------------------------------------------------------
// Lines (FTD37): the weights of each half, as the Unicode names give them
// ---------------------------------------------------------------------------

/// A half's weight.
private enum Weight : ubyte
{
    none,
    light,
    heavy,
    double_,
}

/**
One entry per scalar U+2500–U+257F: the weight of the up, right, down and
left halves, in that order, read off the character's name in the Unicode
Character Database (`-` none, `L` light, `H` heavy, `D` double; "single"
in a name is light). A fifth digit is the dash count of a dashed line. The
arcs (U+256D–U+2570) and diagonals (U+2571–U+2573) have their own geometry
and an empty entry.
*/
private immutable string[0x80] lineHalves = [
    "-L-L",  // 2500 LIGHT HORIZONTAL
    "-H-H",  // 2501 HEAVY HORIZONTAL
    "L-L-",  // 2502 LIGHT VERTICAL
    "H-H-",  // 2503 HEAVY VERTICAL
    "-L-L3", // 2504 LIGHT TRIPLE DASH HORIZONTAL
    "-H-H3", // 2505 HEAVY TRIPLE DASH HORIZONTAL
    "L-L-3", // 2506 LIGHT TRIPLE DASH VERTICAL
    "H-H-3", // 2507 HEAVY TRIPLE DASH VERTICAL
    "-L-L4", // 2508 LIGHT QUADRUPLE DASH HORIZONTAL
    "-H-H4", // 2509 HEAVY QUADRUPLE DASH HORIZONTAL
    "L-L-4", // 250A LIGHT QUADRUPLE DASH VERTICAL
    "H-H-4", // 250B HEAVY QUADRUPLE DASH VERTICAL
    "-LL-",  // 250C LIGHT DOWN AND RIGHT
    "-HL-",  // 250D DOWN LIGHT AND RIGHT HEAVY
    "-LH-",  // 250E DOWN HEAVY AND RIGHT LIGHT
    "-HH-",  // 250F HEAVY DOWN AND RIGHT
    "--LL",  // 2510 LIGHT DOWN AND LEFT
    "--LH",  // 2511 DOWN LIGHT AND LEFT HEAVY
    "--HL",  // 2512 DOWN HEAVY AND LEFT LIGHT
    "--HH",  // 2513 HEAVY DOWN AND LEFT
    "LL--",  // 2514 LIGHT UP AND RIGHT
    "LH--",  // 2515 UP LIGHT AND RIGHT HEAVY
    "HL--",  // 2516 UP HEAVY AND RIGHT LIGHT
    "HH--",  // 2517 HEAVY UP AND RIGHT
    "L--L",  // 2518 LIGHT UP AND LEFT
    "L--H",  // 2519 UP LIGHT AND LEFT HEAVY
    "H--L",  // 251A UP HEAVY AND LEFT LIGHT
    "H--H",  // 251B HEAVY UP AND LEFT
    "LLL-",  // 251C LIGHT VERTICAL AND RIGHT
    "LHL-",  // 251D VERTICAL LIGHT AND RIGHT HEAVY
    "HLL-",  // 251E UP HEAVY AND RIGHT DOWN LIGHT
    "LLH-",  // 251F DOWN HEAVY AND RIGHT UP LIGHT
    "HLH-",  // 2520 VERTICAL HEAVY AND RIGHT LIGHT
    "HHL-",  // 2521 DOWN LIGHT AND RIGHT UP HEAVY
    "LHH-",  // 2522 UP LIGHT AND RIGHT DOWN HEAVY
    "HHH-",  // 2523 HEAVY VERTICAL AND RIGHT
    "L-LL",  // 2524 LIGHT VERTICAL AND LEFT
    "L-LH",  // 2525 VERTICAL LIGHT AND LEFT HEAVY
    "H-LL",  // 2526 UP HEAVY AND LEFT DOWN LIGHT
    "L-HL",  // 2527 DOWN HEAVY AND LEFT UP LIGHT
    "H-HL",  // 2528 VERTICAL HEAVY AND LEFT LIGHT
    "H-LH",  // 2529 DOWN LIGHT AND LEFT UP HEAVY
    "L-HH",  // 252A UP LIGHT AND LEFT DOWN HEAVY
    "H-HH",  // 252B HEAVY VERTICAL AND LEFT
    "-LLL",  // 252C LIGHT DOWN AND HORIZONTAL
    "-LLH",  // 252D LEFT HEAVY AND RIGHT DOWN LIGHT
    "-HLL",  // 252E RIGHT HEAVY AND LEFT DOWN LIGHT
    "-HLH",  // 252F DOWN LIGHT AND HORIZONTAL HEAVY
    "-LHL",  // 2530 DOWN HEAVY AND HORIZONTAL LIGHT
    "-LHH",  // 2531 RIGHT LIGHT AND LEFT DOWN HEAVY
    "-HHL",  // 2532 LEFT LIGHT AND RIGHT DOWN HEAVY
    "-HHH",  // 2533 HEAVY DOWN AND HORIZONTAL
    "LL-L",  // 2534 LIGHT UP AND HORIZONTAL
    "LL-H",  // 2535 LEFT HEAVY AND RIGHT UP LIGHT
    "LH-L",  // 2536 RIGHT HEAVY AND LEFT UP LIGHT
    "LH-H",  // 2537 UP LIGHT AND HORIZONTAL HEAVY
    "HL-L",  // 2538 UP HEAVY AND HORIZONTAL LIGHT
    "HL-H",  // 2539 RIGHT LIGHT AND LEFT UP HEAVY
    "HH-L",  // 253A LEFT LIGHT AND RIGHT UP HEAVY
    "HH-H",  // 253B HEAVY UP AND HORIZONTAL
    "LLLL",  // 253C LIGHT VERTICAL AND HORIZONTAL
    "LLLH",  // 253D LEFT HEAVY AND RIGHT VERTICAL LIGHT
    "LHLL",  // 253E RIGHT HEAVY AND LEFT VERTICAL LIGHT
    "LHLH",  // 253F VERTICAL LIGHT AND HORIZONTAL HEAVY
    "HLLL",  // 2540 UP HEAVY AND DOWN HORIZONTAL LIGHT
    "LLHL",  // 2541 DOWN HEAVY AND UP HORIZONTAL LIGHT
    "HLHL",  // 2542 VERTICAL HEAVY AND HORIZONTAL LIGHT
    "HLLH",  // 2543 LEFT UP HEAVY AND RIGHT DOWN LIGHT
    "HHLL",  // 2544 RIGHT UP HEAVY AND LEFT DOWN LIGHT
    "LLHH",  // 2545 LEFT DOWN HEAVY AND RIGHT UP LIGHT
    "LHHL",  // 2546 RIGHT DOWN HEAVY AND LEFT UP LIGHT
    "HHLH",  // 2547 DOWN LIGHT AND UP HORIZONTAL HEAVY
    "LHHH",  // 2548 UP LIGHT AND DOWN HORIZONTAL HEAVY
    "HLHH",  // 2549 RIGHT LIGHT AND LEFT VERTICAL HEAVY
    "HHHL",  // 254A LEFT LIGHT AND RIGHT VERTICAL HEAVY
    "HHHH",  // 254B HEAVY VERTICAL AND HORIZONTAL
    "-L-L2", // 254C LIGHT DOUBLE DASH HORIZONTAL
    "-H-H2", // 254D HEAVY DOUBLE DASH HORIZONTAL
    "L-L-2", // 254E LIGHT DOUBLE DASH VERTICAL
    "H-H-2", // 254F HEAVY DOUBLE DASH VERTICAL
    "-D-D",  // 2550 DOUBLE HORIZONTAL
    "D-D-",  // 2551 DOUBLE VERTICAL
    "-DL-",  // 2552 DOWN SINGLE AND RIGHT DOUBLE
    "-LD-",  // 2553 DOWN DOUBLE AND RIGHT SINGLE
    "-DD-",  // 2554 DOUBLE DOWN AND RIGHT
    "--LD",  // 2555 DOWN SINGLE AND LEFT DOUBLE
    "--DL",  // 2556 DOWN DOUBLE AND LEFT SINGLE
    "--DD",  // 2557 DOUBLE DOWN AND LEFT
    "LD--",  // 2558 UP SINGLE AND RIGHT DOUBLE
    "DL--",  // 2559 UP DOUBLE AND RIGHT SINGLE
    "DD--",  // 255A DOUBLE UP AND RIGHT
    "L--D",  // 255B UP SINGLE AND LEFT DOUBLE
    "D--L",  // 255C UP DOUBLE AND LEFT SINGLE
    "D--D",  // 255D DOUBLE UP AND LEFT
    "LDL-",  // 255E VERTICAL SINGLE AND RIGHT DOUBLE
    "DLD-",  // 255F VERTICAL DOUBLE AND RIGHT SINGLE
    "DDD-",  // 2560 DOUBLE VERTICAL AND RIGHT
    "L-LD",  // 2561 VERTICAL SINGLE AND LEFT DOUBLE
    "D-DL",  // 2562 VERTICAL DOUBLE AND LEFT SINGLE
    "D-DD",  // 2563 DOUBLE VERTICAL AND LEFT
    "-DLD",  // 2564 DOWN SINGLE AND HORIZONTAL DOUBLE
    "-LDL",  // 2565 DOWN DOUBLE AND HORIZONTAL SINGLE
    "-DDD",  // 2566 DOUBLE DOWN AND HORIZONTAL
    "LD-D",  // 2567 UP SINGLE AND HORIZONTAL DOUBLE
    "DL-L",  // 2568 UP DOUBLE AND HORIZONTAL SINGLE
    "DD-D",  // 2569 DOUBLE UP AND HORIZONTAL
    "LDLD",  // 256A VERTICAL SINGLE AND HORIZONTAL DOUBLE
    "DLDL",  // 256B VERTICAL DOUBLE AND HORIZONTAL SINGLE
    "DDDD",  // 256C DOUBLE VERTICAL AND HORIZONTAL
    "",      // 256D LIGHT ARC DOWN AND RIGHT
    "",      // 256E LIGHT ARC DOWN AND LEFT
    "",      // 256F LIGHT ARC UP AND LEFT
    "",      // 2570 LIGHT ARC UP AND RIGHT
    "",      // 2571 LIGHT DIAGONAL UPPER RIGHT TO LOWER LEFT
    "",      // 2572 LIGHT DIAGONAL UPPER LEFT TO LOWER RIGHT
    "",      // 2573 LIGHT DIAGONAL CROSS
    "---L",  // 2574 LIGHT LEFT
    "L---",  // 2575 LIGHT UP
    "-L--",  // 2576 LIGHT RIGHT
    "--L-",  // 2577 LIGHT DOWN
    "---H",  // 2578 HEAVY LEFT
    "H---",  // 2579 HEAVY UP
    "-H--",  // 257A HEAVY RIGHT
    "--H-",  // 257B HEAVY DOWN
    "-H-L",  // 257C LIGHT LEFT AND HEAVY RIGHT
    "L-H-",  // 257D LIGHT UP AND HEAVY DOWN
    "-L-H",  // 257E HEAVY LEFT AND LIGHT RIGHT
    "H-L-",  // 257F HEAVY UP AND LIGHT DOWN
];

private Weight weightOf(char c)
{
    switch (c)
    {
        case 'L': return Weight.light;
        case 'H': return Weight.heavy;
        case 'D': return Weight.double_;
        default: return Weight.none;
    }
}

/**
One half of a line: its rectangles (one stroke, or two for a double), from
the cell's edge to where FTD37 stops it.

`horizontal` halves run along x and are crossed by the up and down halves
(`perpLow`, `perpHigh`); vertical halves run along y and are crossed by the
left and right halves. `high` is the half on the far side of the centre
(right or down). `opposite` is the other half on the same axis.

$(UL
    $(LI A light or heavy half runs to the far side of the widest light or
        heavy stroke crossing it; with nothing crossing, to the far side of
        a stroke of its own weight. Meeting a double, it crosses to the far
        side of the double, except in a tee — the double runs on both sides
        and the half has no opposite — where it stops at the far side of the
        double's near stroke.)
    $(LI Each stroke of a double half runs to the far side of a crossing
        light stroke, or of a notional double with nothing crossing. Meeting
        a double, a stroke whose side holds a branch of that double stops at
        the far side of the branch's near stroke; the other stroke runs to
        the double's far side. So a corner's outer stroke closes the outer
        corner, and tees and crosses leave the corners between branches
        open.)
)
*/
private void lineHalf(ref Rect[8] rects, ref uint count, in Geometry g, bool horizontal, bool high,
    Weight own, Weight perpLow, Weight perpHigh, Weight opposite)
{
    if (own == Weight.none)
        return;
    const t = g.t;
    const along = horizontal ? g.w : g.h; // the half's own axis
    const across = horizontal ? g.h : g.w; // the axis its strokes are centred on
    const a = floorDiv(along - 3 * t, 2); // a crossing double's strokes: [a, a+t) and [a+2t, a+3t)
    const doubleSpan = Span(a, a + 3 * t);
    const nearStroke = high ? a + 2 * t : a + t; // the far side of the double's near stroke

    int farSide(Span s) => high ? s.lo : s.hi;
    int width(Weight w) => w == Weight.heavy ? 2 * t : t;

    const perpDouble = perpLow == Weight.double_ || perpHigh == Weight.double_;
    const perpAny = perpLow != Weight.none || perpHigh != Weight.none;
    Span crossing = Span(int.max, int.min);
    const Weight[2] perps = [perpLow, perpHigh];
    foreach (p; perps)
        if (p == Weight.light || p == Weight.heavy)
        {
            const s = stroke(along, width(p));
            crossing = Span(s.lo < crossing.lo ? s.lo : crossing.lo, s.hi > crossing.hi ? s.hi : crossing.hi);
        }

    void add(int reach, Span band)
    {
        const run = high ? Span(reach, along) : Span(0, reach);
        rects[count++] = horizontal ? Rect(run.lo, band.lo, run.hi, band.hi)
            : Rect(band.lo, run.lo, band.hi, run.hi);
    }

    if (own != Weight.double_)
    {
        int reach;
        if (!perpAny)
            reach = farSide(stroke(along, width(own)));
        else if (perpDouble)
            reach = opposite == Weight.none && perpLow == Weight.double_ && perpHigh == Weight.double_
                ? nearStroke : farSide(doubleSpan);
        else
            reach = farSide(crossing);
        add(reach, stroke(across, width(own)));
        return;
    }
    const b = floorDiv(across - 3 * t, 2);
    foreach (side; 0 .. 2)
    {
        const branch = side == 0 ? perpLow : perpHigh;
        const band = side == 0 ? Span(b, b + t) : Span(b + 2 * t, b + 3 * t);
        int reach;
        if (!perpAny)
            reach = farSide(doubleSpan);
        else if (perpDouble)
            reach = branch == Weight.double_ ? nearStroke : farSide(doubleSpan);
        else
            reach = farSide(crossing);
        add(reach, band);
    }
}

private void lineShape(Sink)(in Geometry g, string spec, ref Sink sink)
{
    const up = weightOf(spec[0]), right = weightOf(spec[1]), down = weightOf(spec[2]),
        left = weightOf(spec[3]);
    Rect[8] rects;
    uint count;
    if (spec.length > 4)
    {
        // A dashed line: `n` slots along it, each short of its end by `t`.
        const n = spec[4] - '0';
        const horizontal = right != Weight.none;
        const weight = horizontal ? right : up;
        const s = weight == Weight.heavy ? 2 * g.t : g.t;
        const along = horizontal ? g.w : g.h;
        const band = stroke(horizontal ? g.h : g.w, s);
        foreach (i; 0 .. n)
        {
            const lo = i * along / n, hi = (i + 1) * along / n - g.t;
            emitRect(g, sink, horizontal ? Rect(lo, band.lo, hi, band.hi) : Rect(band.lo, lo, band.hi, hi));
        }
        return;
    }
    lineHalf(rects, count, g, true, true, right, up, down, left);
    lineHalf(rects, count, g, true, false, left, up, down, right);
    lineHalf(rects, count, g, false, false, up, left, right, down);
    lineHalf(rects, count, g, false, true, down, left, right, up);
    sink.overlap(anyOverlap(rects[0 .. count]));
    foreach (r; rects[0 .. count])
        emitRect(g, sink, r);
}

// ---------------------------------------------------------------------------
// Arcs and diagonals (FTD37)
// ---------------------------------------------------------------------------

/**
An arc from the vertical light stroke (towards the bottom edge when `down`)
to the horizontal one (towards the right edge when `right`). Its outer and
inner edges are each one quadratic segment with the control point at the
corner of the arc's square, with straight runs on to the cell's edges.

The centre-line radius is `min(⌊w / 2⌋, ⌊h / 2⌋)`, but never more than the
distance from the strokes' centre to the edges the arc runs to: the light
strokes sit a half pixel off centre when `w − t` or `h − t` is odd, and an
arc past the edge would draw into the neighbouring cell.
*/
private void arcShape(Sink)(in Geometry g, bool right, bool down, ref Sink sink)
{
    const k = g.k;
    const v = stroke(g.w, g.t), hz = stroke(g.h, g.t);
    const W = g.w * k, H = g.h * k;
    const xc = (v.lo + v.hi) * k / 2, yc = (hz.lo + hz.hi) * k / 2;
    int r = (g.w / 2 < g.h / 2 ? g.w / 2 : g.h / 2) * k;
    const xRoom = right ? W - xc : xc, yRoom = down ? H - yc : yc;
    if (r > xRoom) r = xRoom;
    if (r > yRoom) r = yRoom;
    const sx = right ? 1 : -1, sy = down ? 1 : -1;
    const outerX = (right ? v.lo : v.hi) * k, innerX = (right ? v.hi : v.lo) * k;
    const outerY = (down ? hz.lo : hz.hi) * k, innerY = (down ? hz.hi : hz.lo) * k;
    const xEnd = right ? W : 0, yEnd = down ? H : 0;
    Contour c;
    c.add(outerX, yEnd);
    c.add(outerX, yc + sy * r);
    c.add(outerX, outerY, false);
    c.add(xc + sx * r, outerY);
    c.add(xEnd, outerY);
    c.add(xEnd, innerY);
    c.add(xc + sx * r, innerY);
    c.add(innerX, innerY, false);
    c.add(innerX, yc + sy * r);
    c.add(innerX, yEnd);
    sink.overlap(false);
    emit(g, sink, c);
}

/**
A diagonal from corner to corner: the band whose horizontal width is `t`,
centred on the line between the corners, clipped to the cell, so diagonals
in neighbouring cells continue each other.
*/
private void diagonal(Sink)(in Geometry g, bool fromTopLeft, ref Sink sink)
{
    const W = double(g.w * g.k), H = double(g.h * g.k), T = g.t * g.k;
    const lo = -double(T / 2), hi = double(T - T / 2);
    double[2][12] poly;
    uint n = 4;
    poly[0] = [fromTopLeft ? lo : W + lo, 0];
    poly[1] = [fromTopLeft ? hi : W + hi, 0];
    poly[2] = [fromTopLeft ? W + hi : hi, H];
    poly[3] = [fromTopLeft ? W + lo : lo, H];
    // Sutherland–Hodgman against x ≥ 0, x ≤ W, y ≥ 0, y ≤ H.
    foreach (edge; 0 .. 4)
    {
        const axis = edge / 2;
        const limit = edge % 2 == 0 ? 0.0 : (axis == 0 ? W : H);
        bool inside(in double[2] p) => edge % 2 == 0 ? p[axis] >= limit : p[axis] <= limit;
        double[2][12] next;
        uint m;
        foreach (i; 0 .. n)
        {
            const p = poly[i], q = poly[(i + 1) % n];
            const pin = inside(p), qin = inside(q);
            if (pin)
                next[m++] = p;
            if (pin != qin)
            {
                const f = (limit - p[axis]) / (q[axis] - p[axis]);
                double[2] x = [p[0] + f * (q[0] - p[0]), p[1] + f * (q[1] - p[1])];
                x[axis] = limit;
                next[m++] = x;
            }
        }
        poly = next;
        n = m;
    }
    Contour c;
    foreach (p; poly[0 .. n])
        c.add(cast(int) floor(p[0] + 0.5), cast(int) floor(p[1] + 0.5));
    emit(g, sink, c);
}

// ---------------------------------------------------------------------------
// Blocks and shades (FTD37)
// ---------------------------------------------------------------------------

/**
U+2580–U+259F in eighths of the cell, as their Unicode names give them:
`[x0, y0, x1, y1]`, edges at `⌊i · w / 8⌋` and `⌊i · h / 8⌋`. A quadrant
character lists its quadrants, up to three, and the shades (U+2591–U+2593)
have none.
*/
private immutable ubyte[4][][0x20] blockRects = [
    [[0, 0, 8, 4]], // 2580 UPPER HALF BLOCK
    [[0, 7, 8, 8]], // 2581 LOWER ONE EIGHTH BLOCK
    [[0, 6, 8, 8]], // 2582 LOWER ONE QUARTER BLOCK
    [[0, 5, 8, 8]], // 2583 LOWER THREE EIGHTHS BLOCK
    [[0, 4, 8, 8]], // 2584 LOWER HALF BLOCK
    [[0, 3, 8, 8]], // 2585 LOWER FIVE EIGHTHS BLOCK
    [[0, 2, 8, 8]], // 2586 LOWER THREE QUARTERS BLOCK
    [[0, 1, 8, 8]], // 2587 LOWER SEVEN EIGHTHS BLOCK
    [[0, 0, 8, 8]], // 2588 FULL BLOCK
    [[0, 0, 7, 8]], // 2589 LEFT SEVEN EIGHTHS BLOCK
    [[0, 0, 6, 8]], // 258A LEFT THREE QUARTERS BLOCK
    [[0, 0, 5, 8]], // 258B LEFT FIVE EIGHTHS BLOCK
    [[0, 0, 4, 8]], // 258C LEFT HALF BLOCK
    [[0, 0, 3, 8]], // 258D LEFT THREE EIGHTHS BLOCK
    [[0, 0, 2, 8]], // 258E LEFT ONE QUARTER BLOCK
    [[0, 0, 1, 8]], // 258F LEFT ONE EIGHTH BLOCK
    [[4, 0, 8, 8]], // 2590 RIGHT HALF BLOCK
    [], // 2591 LIGHT SHADE
    [], // 2592 MEDIUM SHADE
    [], // 2593 DARK SHADE
    [[0, 0, 8, 1]], // 2594 UPPER ONE EIGHTH BLOCK
    [[7, 0, 8, 8]], // 2595 RIGHT ONE EIGHTH BLOCK
    [[0, 4, 4, 8]], // 2596 QUADRANT LOWER LEFT
    [[4, 4, 8, 8]], // 2597 QUADRANT LOWER RIGHT
    [[0, 0, 4, 4]], // 2598 QUADRANT UPPER LEFT
    [[0, 0, 4, 4], [0, 4, 4, 8], [4, 4, 8, 8]], // 2599 UPPER LEFT AND LOWER LEFT AND LOWER RIGHT
    [[0, 0, 4, 4], [4, 4, 8, 8]], // 259A UPPER LEFT AND LOWER RIGHT
    [[0, 0, 4, 4], [4, 0, 8, 4], [0, 4, 4, 8]], // 259B UPPER LEFT AND UPPER RIGHT AND LOWER LEFT
    [[0, 0, 4, 4], [4, 0, 8, 4], [4, 4, 8, 8]], // 259C UPPER LEFT AND UPPER RIGHT AND LOWER RIGHT
    [[4, 0, 8, 4]], // 259D QUADRANT UPPER RIGHT
    [[4, 0, 8, 4], [0, 4, 4, 8]], // 259E UPPER RIGHT AND LOWER LEFT
    [[4, 0, 8, 4], [0, 4, 4, 8], [4, 4, 8, 8]], // 259F UPPER RIGHT AND LOWER LEFT AND LOWER RIGHT
];

private void blockShape(Sink)(in Geometry g, uint cp, ref Sink sink)
{
    sink.overlap(false);
    if (cp >= 0x2591 && cp <= 0x2593)
    {
        // A 2×2 pattern of u-pixel squares: light fills the top-left of
        // each, medium the diagonal pair, dark all but the bottom-right.
        const u = ((g.w > g.h ? g.w : g.h) + 63) / 64;
        for (int j = 0; j * u < g.h; ++j)
            for (int i = 0; i * u < g.w; ++i)
            {
                const odd = (i & 1) + 2 * (j & 1); // 0 top-left … 3 bottom-right
                const filled = cp == 0x2591 ? odd == 0 : cp == 0x2592 ? odd == 0 || odd == 3 : odd != 3;
                if (!filled)
                    continue;
                const x1 = (i + 1) * u, y1 = (j + 1) * u;
                emitRect(g, sink, Rect(i * u, j * u, x1 < g.w ? x1 : g.w, y1 < g.h ? y1 : g.h));
            }
        return;
    }
    foreach (q; blockRects[cp - 0x2580])
        emitRect(g, sink, Rect(q[0] * g.w / 8, q[1] * g.h / 8, q[2] * g.w / 8, q[3] * g.h / 8));
}

/// Drives `sink` with the contours of `cp`, U+2500–U+259F.
private void glyphShape(Sink)(in Geometry g, uint cp, ref Sink sink)
{
    if (cp >= 0x2580)
        return blockShape(g, cp, sink);
    switch (cp)
    {
        case 0x256D: return arcShape(g, true, true, sink);
        case 0x256E: return arcShape(g, false, true, sink);
        case 0x256F: return arcShape(g, false, false, sink);
        case 0x2570: return arcShape(g, true, false, sink);
        case 0x2571, 0x2572:
            sink.overlap(false);
            return diagonal(g, cp == 0x2572, sink);
        case 0x2573:
            sink.overlap(true);
            diagonal(g, true, sink);
            return diagonal(g, false, sink);
        default:
            return lineShape(g, lineHalves[cp - 0x2500], sink);
    }
}

// ---------------------------------------------------------------------------
// glyf encoding
// ---------------------------------------------------------------------------

/// Bytes out: counted when not `writing`, written into `buf` otherwise.
private struct Out
{
    @safe pure nothrow @nogc:

    ubyte[] buf;
    size_t at;
    bool writing;

    void u8(uint v)
    {
        if (writing)
            buf[at] = cast(ubyte) v;
        ++at;
    }

    void u16(uint v)
    {
        u8(v >> 8);
        u8(v);
    }

    void u32(uint v)
    {
        u16(v >> 16);
        u16(v);
    }

    void pad4()
    {
        while (at % 4)
            u8(0);
    }

    void patch32(size_t pos, uint v)
    {
        if (!writing)
            return;
        foreach (i; 0 .. 4)
            buf[pos + i] = cast(ubyte)(v >> (24 - 8 * i));
    }
}

/// A glyph's counts and bounds, from a first pass over its contours.
private struct Stats
{
    @safe pure nothrow @nogc:

    uint contours, points;
    int xMin = int.max, yMin = int.max, xMax = int.min, yMax = int.min;
    bool overlap;
}

private struct StatsSink
{
    @safe pure nothrow @nogc:

    Stats s;

    void overlap(bool v) { s.overlap = v; }

    void contour(scope const(Pt)[] pts)
    {
        ++s.contours;
        s.points += cast(uint) pts.length;
        foreach (p; pts)
        {
            if (p.x < s.xMin) s.xMin = p.x;
            if (p.x > s.xMax) s.xMax = p.x;
            if (p.y < s.yMin) s.yMin = p.y;
            if (p.y > s.yMax) s.yMax = p.y;
        }
    }
}

/// Which stream of a simple glyph a pass writes.
private enum Stream : ubyte
{
    ends,
    flags,
    xs,
    ys,
}

private struct StreamSink
{
    @safe pure nothrow @nogc:

    Out o;
    Stream stream;
    bool overlapFlag;
    uint points;
    int px, py;

    void overlap(bool) {}

    void contour(scope const(Pt)[] pts)
    {
        foreach (p; pts)
        {
            const dx = p.x - px, dy = p.y - py;
            final switch (stream)
            {
                case Stream.ends:
                    break;
                case Stream.flags:
                    uint f = p.on ? 0x01 : 0;
                    f |= dx == 0 ? 0x10 : dx >= -255 && dx <= 255 ? 0x02 | (dx > 0 ? 0x10 : 0) : 0;
                    f |= dy == 0 ? 0x20 : dy >= -255 && dy <= 255 ? 0x04 | (dy > 0 ? 0x20 : 0) : 0;
                    if (points == 0 && overlapFlag)
                        f |= 0x40; // OVERLAP_SIMPLE (FTX9)
                    o.u8(f);
                    break;
                case Stream.xs:
                    delta(dx);
                    break;
                case Stream.ys:
                    delta(dy);
                    break;
            }
            px = p.x;
            py = p.y;
            ++points;
        }
        if (stream == Stream.ends)
            o.u16(points - 1);
    }

    private void delta(int d)
    {
        if (d == 0)
            return;
        if (d >= -255 && d <= 255)
            o.u8(d < 0 ? -d : d);
        else
            o.u16(cast(ushort) cast(short) d);
    }
}

/// Writes glyph `cp`'s `glyf` entry, whose first pass found `st`.
private void writeGlyph(ref Out o, in Geometry g, uint cp, in Stats st)
{
    o.u16(cast(ushort) st.contours);
    o.u16(cast(ushort) cast(short) st.xMin);
    o.u16(cast(ushort) cast(short) st.yMin);
    o.u16(cast(ushort) cast(short) st.xMax);
    o.u16(cast(ushort) cast(short) st.yMax);
    static immutable Stream[4] streams = [Stream.ends, Stream.flags, Stream.xs, Stream.ys];
    foreach (stream; streams)
    {
        auto sink = StreamSink(o, stream, st.overlap);
        glyphShape(g, cp, sink);
        o = sink.o;
        if (stream == Stream.ends)
            o.u16(0); // no instructions
    }
}

// ---------------------------------------------------------------------------
// The font
// ---------------------------------------------------------------------------

/// The tables in tag order, as the directory lists them.
private enum TableId : ubyte
{
    os2,
    cmap,
    glyf,
    head,
    hhea,
    hmtx,
    loca,
    maxp,
    name,
    post,
}

private immutable uint[10] tableTags = [0x4F53_2F32, 0x636D_6170, 0x676C_7966, 0x6865_6164,
    0x6868_6561, 0x686D_7478, 0x6C6F_6361, 0x6D61_7870, 0x6E61_6D65, 0x706F_7374];

/// The sum of big-endian words of `data`, zero-padded.
private uint checksum(scope const(ubyte)[] data)
{
    uint sum;
    for (size_t i = 0; i < data.length; i += 4)
    {
        uint word;
        foreach (j; 0 .. 4)
            word = (word << 8) | (i + j < data.length ? data[i + j] : 0);
        sum += word;
    }
    return sum;
}

/// Writes `n` in decimal.
private void decimal(ref char[64] text, ref size_t at, uint n)
{
    char[10] digits;
    size_t count;
    do
    {
        digits[count++] = cast(char)('0' + n % 10);
        n /= 10;
    }
    while (n);
    while (count)
        text[at++] = digits[--count];
}

/// Appends `s` to `text`.
private void append(ref char[64] text, ref size_t at, scope const(char)[] s)
{
    text[at .. at + s.length] = s;
    at += s.length;
}

/**
Writes (or, through a counting `o`, sizes) the whole font. The file holds
`glyf` first, so every later table knows the glyphs' bounds; the directory
lists the tables in tag order.
*/
private FontResult!bool writeFont(ref Out o, in Geometry g)
{
    enum uint tableCount = 10;
    const k = g.k;
    const upem = g.ppem * k;
    const advance = g.w * k;
    const ascender = g.baseline * k;
    const descender = -(g.h - g.baseline) * k;

    // The sfnt header and a directory filled in at the end.
    o.u32(0x0001_0000);
    o.u16(tableCount);
    o.u16(128); // searchRange: 16 · 8
    o.u16(3); // entrySelector
    o.u16(tableCount * 16 - 128); // rangeShift
    const directory = o.at;
    foreach (_; 0 .. tableCount * 16)
        o.u8(0);
    uint[2][tableCount] spans; // offset, length

    void begin(TableId id) { spans[id][0] = cast(uint) o.at; }
    void end(TableId id)
    {
        spans[id][1] = cast(uint)(o.at - spans[id][0]);
        o.pad4();
    }

    // glyf: .notdef and the space are empty; then U+2500–U+259F.
    uint[boxFaceGlyphCount + 1] offsets;
    short[boxFaceGlyphCount] lsb;
    int xMin = int.max, yMin = int.max, xMax = int.min, yMax = int.min;
    int minRsb = int.max;
    uint maxPoints, maxContours;
    begin(TableId.glyf);
    foreach (gid; 0 .. boxFaceGlyphCount)
    {
        offsets[gid] = cast(uint)(o.at - spans[TableId.glyf][0]);
        if (gid < 2)
            continue;
        const cp = 0x2500 + gid - 2;
        StatsSink stats;
        glyphShape(g, cp, stats);
        const st = stats.s;
        if (st.contours == 0)
            continue;
        if (st.xMin < short.min || st.yMin < short.min || st.xMax > short.max || st.yMax > short.max
            || st.points > ushort.max || st.contours > short.max)
            return fontErr!bool(FontError(FontErrorKind.limitExceeded));
        writeGlyph(o, g, cp, st);
        o.pad4();
        lsb[gid] = cast(short) st.xMin;
        if (st.xMin < xMin) xMin = st.xMin;
        if (st.yMin < yMin) yMin = st.yMin;
        if (st.xMax > xMax) xMax = st.xMax;
        if (st.yMax > yMax) yMax = st.yMax;
        if (advance - st.xMax < minRsb) minRsb = advance - st.xMax;
        if (st.points > maxPoints) maxPoints = st.points;
        if (st.contours > maxContours) maxContours = st.contours;
    }
    offsets[boxFaceGlyphCount] = cast(uint)(o.at - spans[TableId.glyf][0]);
    end(TableId.glyf);

    begin(TableId.loca);
    foreach (offset; offsets)
        o.u32(offset);
    end(TableId.loca);

    begin(TableId.head);
    o.u32(0x0001_0000); // version 1.0
    o.u32(0x0001_0000); // fontRevision
    const adjustmentAt = o.at;
    o.u32(0); // checkSumAdjustment, set last
    o.u32(0x5F0F_3CF5); // magicNumber
    o.u16(0x0009); // flags: baseline at y = 0, integer ppem
    o.u16(upem);
    foreach (_; 0 .. 4)
        o.u32(0); // created, modified
    o.u16(cast(ushort) cast(short) xMin);
    o.u16(cast(ushort) cast(short) yMin);
    o.u16(cast(ushort) cast(short) xMax);
    o.u16(cast(ushort) cast(short) yMax);
    o.u16(0); // macStyle
    o.u16(g.ppem); // lowestRecPPEM
    o.u16(2); // fontDirectionHint
    o.u16(1); // indexToLocFormat: long
    o.u16(0); // glyphDataFormat
    end(TableId.head);

    begin(TableId.hhea);
    o.u32(0x0001_0000);
    o.u16(cast(ushort) ascender);
    o.u16(cast(ushort) cast(short) descender);
    o.u16(0); // lineGap
    o.u16(advance); // advanceWidthMax
    o.u16(cast(ushort) cast(short) xMin); // minLeftSideBearing: lsb is xMin
    o.u16(cast(ushort) cast(short) minRsb);
    o.u16(cast(ushort) cast(short) xMax); // xMaxExtent: lsb + (xMax − xMin)
    o.u16(1); // caretSlopeRise
    o.u16(0); // caretSlopeRun
    o.u16(0); // caretOffset
    foreach (_; 0 .. 4)
        o.u16(0);
    o.u16(0); // metricDataFormat
    o.u16(boxFaceGlyphCount); // numberOfHMetrics
    end(TableId.hhea);

    begin(TableId.maxp);
    o.u32(0x0001_0000);
    o.u16(boxFaceGlyphCount);
    o.u16(maxPoints);
    o.u16(maxContours);
    o.u16(0); // maxCompositePoints
    o.u16(0); // maxCompositeContours
    o.u16(2); // maxZones
    foreach (_; 0 .. 8)
        o.u16(0); // twilight points … component depth
    end(TableId.maxp);

    begin(TableId.os2);
    o.u16(4); // version
    o.u16(advance); // xAvgCharWidth
    o.u16(400); // usWeightClass
    o.u16(5); // usWidthClass
    o.u16(0); // fsType: installable
    const sub = upem * 65 / 100;
    o.u16(sub); // ySubscriptXSize
    o.u16(sub); // ySubscriptYSize
    o.u16(0); // ySubscriptXOffset
    o.u16(upem * 14 / 100); // ySubscriptYOffset
    o.u16(sub); // ySuperscriptXSize
    o.u16(sub); // ySuperscriptYSize
    o.u16(0); // ySuperscriptXOffset
    o.u16(upem * 48 / 100); // ySuperscriptYOffset
    const strike = stroke(g.h, g.t);
    o.u16(g.t * k); // yStrikeoutSize
    o.u16(cast(ushort) cast(short)(ascender - strike.lo * k)); // yStrikeoutPosition: the light line's top
    o.u16(0); // sFamilyClass
    foreach (i; 0 .. 10)
        o.u8(i == 0 ? 2 : i == 3 ? 9 : 0); // PANOSE: Latin text, monospaced
    o.u32(0x0000_0001); // ulUnicodeRange1: Basic Latin
    o.u32(0x0000_C000); // ulUnicodeRange2: Box Drawing (46), Block Elements (47)
    o.u32(0);
    o.u32(0);
    o.u32(0x5350_4B4C); // achVendID 'SPKL'
    o.u16(0x00C0); // fsSelection: REGULAR, USE_TYPO_METRICS
    o.u16(0x0020); // usFirstCharIndex
    o.u16(0x259F); // usLastCharIndex
    o.u16(cast(ushort) ascender); // sTypoAscender
    o.u16(cast(ushort) cast(short) descender); // sTypoDescender
    o.u16(0); // sTypoLineGap
    o.u16(ascender); // usWinAscent
    o.u16(-descender); // usWinDescent
    o.u32(0); // ulCodePageRange1
    o.u32(0x8000_0000); // ulCodePageRange2: IBM PC (437)
    o.u16(0); // sxHeight
    o.u16(0); // sCapHeight
    o.u16(0); // usDefaultChar
    o.u16(0x20); // usBreakChar
    o.u16(0); // usMaxContext
    end(TableId.os2);

    begin(TableId.hmtx);
    foreach (gid; 0 .. boxFaceGlyphCount)
    {
        o.u16(advance);
        o.u16(cast(ushort) lsb[gid]);
    }
    end(TableId.hmtx);

    begin(TableId.cmap);
    o.u16(0); // version
    o.u16(1); // one encoding record
    o.u16(3); // Windows
    o.u16(1); // Unicode BMP
    o.u32(12);
    // Format 4: U+0020, U+2500–U+259F and the 0xFFFF terminator.
    enum uint segments = 3;
    o.u16(4);
    o.u16(16 + 8 * segments); // length
    o.u16(0); // language
    o.u16(2 * segments);
    o.u16(4); // searchRange: 2 · 2^⌊log2 3⌋
    o.u16(1); // entrySelector
    o.u16(2 * segments - 4); // rangeShift
    static immutable ushort[segments] endCodes = [0x0020, 0x259F, 0xFFFF];
    static immutable ushort[segments] startCodes = [0x0020, 0x2500, 0xFFFF];
    static immutable ushort[segments] deltas = [cast(ushort)(1 - 0x20), cast(ushort)(2 - 0x2500), 1];
    foreach (e; endCodes)
        o.u16(e);
    o.u16(0); // reservedPad
    foreach (s; startCodes)
        o.u16(s);
    foreach (d; deltas)
        o.u16(d); // idDelta, modulo 65,536
    foreach (_; 0 .. segments)
        o.u16(0); // idRangeOffset
    end(TableId.cmap);

    begin(TableId.name);
    {
        char[64] unique;
        size_t uniqueLength;
        append(unique, uniqueLength, boxFaceFamily);
        append(unique, uniqueLength, " ");
        decimal(unique, uniqueLength, cast(uint) g.w);
        append(unique, uniqueLength, "x");
        decimal(unique, uniqueLength, cast(uint) g.h);
        append(unique, uniqueLength, " ");
        decimal(unique, uniqueLength, g.ppem);
        append(unique, uniqueLength, "ppem");
        const(char)[][6] strings = [boxFaceFamily, "Regular", unique[0 .. uniqueLength], boxFaceFamily,
            "Version 1.000", "SparklesBoxDrawing"];
        o.u16(0); // format
        o.u16(strings.length);
        o.u16(6 + 12 * strings.length); // storageOffset
        uint stored;
        foreach (i, s; strings)
        {
            o.u16(3); // Windows
            o.u16(1); // Unicode BMP
            o.u16(0x0409); // English (United States)
            o.u16(cast(uint) i + 1); // nameID 1–6
            o.u16(cast(uint)(2 * s.length));
            o.u16(stored);
            stored += 2 * s.length;
        }
        foreach (s; strings)
            foreach (c; s)
                o.u16(c); // UTF-16BE of ASCII
    }
    end(TableId.name);

    begin(TableId.post);
    o.u32(0x0003_0000);
    o.u32(0); // italicAngle
    o.u16(cast(ushort) cast(short) g.underlinePosition);
    o.u16(cast(ushort) g.underlineThickness);
    o.u32(1); // isFixedPitch
    foreach (_; 0 .. 4)
        o.u32(0); // memory hints
    end(TableId.post);

    if (o.writing)
    {
        foreach (i; 0 .. tableCount)
        {
            const at = directory + 16 * i;
            const span = spans[i];
            o.patch32(at, tableTags[i]);
            // `head`'s checksum is taken with its adjustment as zero, as it is now.
            o.patch32(at + 4, checksum(o.buf[span[0] .. span[0] + span[1]]));
            o.patch32(at + 8, span[0]);
            o.patch32(at + 12, span[1]);
        }
        o.patch32(adjustmentAt, 0xB1B0_AFBA - checksum(o.buf[0 .. o.at]));
    }
    return fontOk(true);
}
