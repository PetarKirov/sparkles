/**
Light hinting: vertical-only grid fitting of outlines before
rasterization (`docs/specs/font/SPEC.md` FTR9, decision FTX17).

At terminal sizes the softness of unhinted text is mostly vertical: a
baseline, an x-height or a crossbar that falls between two pixel rows is
drawn as two half-grey rows. Light hinting moves those horizontal edges onto
pixel boundaries and leaves everything horizontal — shapes, side bearings,
advances — exactly as designed, which is what FreeType's auto-hinter does in
its light mode and what most Linux desktops and browsers draw with.

$(LREF lightHints) measures a face once per size: the blue zones (baseline,
x-height, cap height, ascender, descender) from reference glyphs, and a
vertical scale that puts the x-height on a whole pixel. $(LREF hintSegments)
then fits one glyph's decoded outline:

$(OL
    $(LI Its horizontal edges are found — flat runs, and the tops and
    bottoms of round strokes — each knowing which side its ink is on.)
    $(LI An edge inside a blue zone snaps to the zone's pixel row: a flat
    one to the zone's reference, a round one to its overshoot.)
    $(LI A stem — a top edge over a bottom edge, close enough to be one
    stroke — keeps a whole number of pixels of width, at least one, and
    lands on the grid as a unit.)
    $(LI Every other edge rounds to the nearest pixel row; positions stay
    in their original order.)
    $(LI Every point's y is mapped piecewise linearly between the fitted
    edges, so curves bend smoothly into place.)
)

Hinting never changes an advance (FTM's physical metrics stay exact) and,
like the rest of the rasterizer, allocates nothing: a glyph with more edges
than the fixed tables hold is left unhinted.
*/
module sparkles.font.hinting;

import sparkles.font.cmap : CharMap;
import sparkles.font.errors : FontResult, fontOk;
import sparkles.font.instance : Instance;
import sparkles.font.outlines : glyphOutline, OutlinePoint, OutlineSegment, OutlineWorkspace, SegmentKind;
import sparkles.font.units : DesignValue, Ppem, toPixels;

@safe pure nothrow @nogc:

/// How outlines meet the pixel grid.
enum Hinting : ubyte
{
    none,  /// as designed
    light, /// vertical-only grid fitting
}

/// One blue zone: a reference height and its overshoot, in 1/65,536 font units.
struct BlueZone
{
    long reference; /// where flat edges sit
    long overshoot; /// where round edges sit
    bool top;       /// a zone for top edges (ink below), else bottom edges
    double referencePx; /// the reference's fitted pixel row
    double overshootPx; /// the overshoot's
}

/// A face's light-hinting metrics at one size, from `lightHints`.
struct LightHints
{
    @safe pure nothrow @nogc:

    /// Pixels per 1/65,536 font unit: the rasterizer's scale, which `x` keeps.
    double scale = 0;
    /// The vertical scale: `scale` adjusted so the x-height is a whole pixel.
    double yScale = 0;
    BlueZone[5] zones; ///
    size_t zoneCount;  ///
    long fuzz;         /// how far outside a zone an edge may be and still snap
    long stemMax;      /// the widest horizontal stroke treated as a stem
    long flatness;     /// how far a segment's ends may differ in y and still be flat

    /// Whether these hints apply to anything.
    bool valid() const => scale > 0 && yScale > 0;
}

/**
The light-hinting metrics of `inst` at `ppem`: the blue zones measured from
the face's own glyphs for `x`, `o`, `H`, `O`, `d` and `p` (a zone whose
glyphs the face lacks is left out), and the vertical scale that puts the
x-height on a whole pixel. `segments` and `ws` are decoding scratch, as
`glyphOutline` takes them. A face with no x-height reference gets hints that
fit edges to the grid without zones.
*/
LightHints lightHints(in Instance inst, in CharMap map, Ppem ppem, scope OutlineSegment[] segments,
    scope OutlineWorkspace ws)
{
    LightHints h;
    const upem = inst.unitsPerEm;
    h.scale = toPixels(DesignValue.fromUnits(1, upem), ppem) / 65_536.0;
    h.yScale = h.scale;
    h.fuzz = (long(upem) << 16) / 64;
    h.stemMax = (long(upem) << 16) / 5;
    h.flatness = 2L << 16;

    // A glyph's lowest and highest points, in 1/65,536 units.
    bool extent(dchar c, out long low, out long high)
    {
        const gid = map.glyph(c);
        if (gid == 0)
            return false;
        const outline = glyphOutline(inst, gid, segments, ws);
        if (outline.hasError || outline.value.segmentCount == 0)
            return false;
        low = long.max;
        high = long.min;
        foreach (s; segments[0 .. outline.value.segmentCount])
            if (s.kind != SegmentKind.close)
            {
                low = s.end.y < low ? s.end.y : low;
                high = s.end.y > high ? s.end.y : high;
            }
        return true;
    }

    long xLow, xHigh, oLow, oHigh, hLow, hHigh, bigOLow, bigOHigh, dLow, dHigh, pLow, pHigh;
    const haveX = extent('x', xLow, xHigh), haveO = extent('o', oLow, oHigh);
    if (haveX)
    {
        // The x-height — its overshoot, where round letters top out — on a
        // whole pixel, the rest of the glyph scaled with it. Rounded up from
        // three eighths, as FreeType's auto-hinter does: a taller x-height
        // reads better than a squatter one.
        const xh = (haveO ? oHigh : xHigh) * h.scale;
        const fitted = xh < 1 ? 1 : cast(double) cast(long)(xh + 0.625);
        if (xh > 0)
            h.yScale = h.scale * fitted / xh;
        h.add(xLow, haveO ? oLow : xLow, false);
        h.add(xHigh, haveO ? oHigh : xHigh, true);
    }
    if (extent('H', hLow, hHigh))
    {
        const haveBigO = extent('O', bigOLow, bigOHigh);
        h.add(hHigh, haveBigO ? bigOHigh : hHigh, true);
    }
    if (extent('d', dLow, dHigh))
        h.add(dHigh, dHigh, true);
    if (extent('p', pLow, pHigh))
        h.add(pLow, pLow, false);
    return h;
}

private void add(ref LightHints h, long reference, long overshoot, bool top)
{
    if (h.zoneCount == h.zones.length)
        return;
    BlueZone z = BlueZone(reference, overshoot, top);
    z.referencePx = roundPx(reference * h.yScale);
    // An overshoot under half a pixel rounds away: round letters stand as
    // tall as flat ones at small sizes, as every hinter draws them.
    z.overshootPx = z.referencePx + roundPx((overshoot - reference) * h.yScale);
    h.zones[h.zoneCount++] = z;
}

private double roundPx(double v) => v >= 0 ? cast(double) cast(long)(v + 0.5) : -cast(double) cast(long)(-v + 0.5);

/// The most edges one glyph is fitted with; a glyph with more is left as drawn.
enum size_t maxHintEdges = 96;

/**
Fits the decoded outline `segments` to the pixel grid vertically, in place,
by `hints` (see the module header). Coordinates stay in 1/65,536 font units,
so the rasterizer draws the result at the same scale as an unhinted outline.
Invalid hints, and a glyph with more than `maxHintEdges` candidate edges,
leave the outline untouched.
*/
void hintSegments(scope OutlineSegment[] segments, in LightHints hints)
{
    if (!hints.valid || !segments.length)
        return;

    Edge[maxHintEdges] found;
    size_t count;
    const inkLeft = signedArea(segments) > 0;
    if (!findEdges(segments, hints, inkLeft, found, count))
        return;
    auto edges = found[0 .. count];
    sortEdges(edges);
    count = mergeEdges(edges, hints.flatness);
    edges = found[0 .. count];
    fitEdges(edges, hints);

    // Every point's y, mapped between the fitted edges.
    double map(long y)
    {
        if (!edges.length)
            return y * hints.yScale;
        if (y <= edges[0].y)
            return edges[0].target + (y - edges[0].y) * hints.yScale;
        if (y >= edges[$ - 1].y)
            return edges[$ - 1].target + (y - edges[$ - 1].y) * hints.yScale;
        foreach (i; 1 .. edges.length)
            if (y <= edges[i].y)
            {
                const a = edges[i - 1], b = edges[i];
                const t = b.y == a.y ? 0.0 : cast(double)(y - a.y) / (b.y - a.y);
                return a.target + (b.target - a.target) * t;
            }
        return edges[$ - 1].target;
    }

    long units(double px) => cast(long)(px / hints.scale + (px >= 0 ? 0.5 : -0.5));
    foreach (ref s; segments)
    {
        if (s.kind == SegmentKind.close)
            continue;
        s.end.y = units(map(s.end.y));
        if (s.kind == SegmentKind.quadTo || s.kind == SegmentKind.cubicTo)
            s.control1.y = units(map(s.control1.y));
        if (s.kind == SegmentKind.cubicTo)
            s.control2.y = units(map(s.control2.y));
    }
}

/// A horizontal edge: where it is, which side its ink is on, and where it goes.
struct Edge
{
    long y;           /// in 1/65,536 font units
    bool top;         /// ink below it (a top edge), else above
    bool flat;        /// a flat run, rather than a round extreme
    bool fitted;      ///
    double target = 0; /// its fitted pixel row
}

// Twice the outline's signed area over its on-curve points: positive when
// the outer contours run counter-clockwise (CFF), so ink is on the left of
// the direction of travel; negative for TrueType's clockwise outlines.
private double signedArea(scope const(OutlineSegment)[] segments)
{
    double area = 0;
    OutlinePoint start, current;
    foreach (s; segments)
        final switch (s.kind)
        {
            case SegmentKind.moveTo:
                start = current = s.end;
                break;
            case SegmentKind.lineTo:
            case SegmentKind.quadTo:
            case SegmentKind.cubicTo:
                area += (cast(double) current.x * s.end.y - cast(double) s.end.x * current.y);
                current = s.end;
                break;
            case SegmentKind.close:
                area += (cast(double) current.x * start.y - cast(double) start.x * current.y);
                current = start;
                break;
        }
    return area;
}

// The candidate edges: flat lines, and on-curve points where a curve's
// tangent is horizontal. Travel in +x with ink on the left puts the ink above.
private bool findEdges(scope const(OutlineSegment)[] segments, in LightHints hints, bool inkLeft,
    ref Edge[maxHintEdges] edges, ref size_t count)
{
    bool put(long y, long dx, bool flat)
    {
        if (dx == 0)
            return true;
        if (count == edges.length)
            return false;
        const inkAbove = (dx > 0) == inkLeft;
        edges[count++] = Edge(y, !inkAbove, flat);
        return true;
    }

    OutlinePoint start, current;
    foreach (s; segments)
    {
        switch (s.kind)
        {
            case SegmentKind.moveTo:
                start = current = s.end;
                continue;
            case SegmentKind.close:
                if (abs(start.y - current.y) <= hints.flatness && !put((start.y + current.y) / 2,
                        start.x - current.x, true))
                    return false;
                current = start;
                continue;
            case SegmentKind.lineTo:
                if (abs(s.end.y - current.y) <= hints.flatness && !put((s.end.y + current.y) / 2,
                        s.end.x - current.x, true))
                    return false;
                break;
            default:
                // A curve leaving or arriving horizontally marks a round extreme.
                const last = s.kind == SegmentKind.cubicTo ? s.control2 : s.control1;
                if (abs(s.control1.y - current.y) <= hints.flatness
                        && !put(current.y, s.control1.x - current.x, false))
                    return false;
                if (abs(last.y - s.end.y) <= hints.flatness && !put(s.end.y, s.end.x - last.x, false))
                    return false;
                break;
        }
        current = s.end;
    }
    return true;
}

private long abs(long v) => v < 0 ? -v : v;

private void sortEdges(scope Edge[] edges)
{
    foreach (i; 1 .. edges.length)
    {
        auto e = edges[i];
        size_t j = i;
        for (; j > 0 && (edges[j - 1].y > e.y || edges[j - 1].y == e.y && edges[j - 1].top && !e.top); --j)
            edges[j] = edges[j - 1];
        edges[j] = e;
    }
}

// Edges at one height with one ink side are one edge; flat wins over round.
private size_t mergeEdges(scope Edge[] edges, long tolerance)
{
    size_t kept;
    foreach (e; edges)
    {
        if (kept && edges[kept - 1].top == e.top && e.y - edges[kept - 1].y <= tolerance)
        {
            edges[kept - 1].flat |= e.flat;
            continue;
        }
        edges[kept++] = e;
    }
    return kept;
}

private void fitEdges(scope Edge[] edges, in LightHints h)
{
    // Blue zones first: they are the lines a reader's eye runs along.
    foreach (ref e; edges)
        foreach (z; h.zones[0 .. h.zoneCount])
        {
            const low = (z.reference < z.overshoot ? z.reference : z.overshoot) - h.fuzz;
            const high = (z.reference > z.overshoot ? z.reference : z.overshoot) + h.fuzz;
            if (z.top != e.top || e.y < low || e.y > high)
                continue;
            const nearerReference = abs(e.y - z.reference) <= abs(e.y - z.overshoot);
            e.target = e.flat || nearerReference ? z.referencePx : z.overshootPx;
            e.fitted = true;
            break;
        }
    // Stems: a bottom edge with the nearest top edge above it, close enough
    // to be one stroke, keep a whole number of pixels between them.
    foreach (i, ref bottom; edges)
    {
        if (bottom.top)
            continue;
        foreach (ref top; edges[i + 1 .. $])
        {
            if (!top.top)
                continue;
            if (top.y - bottom.y > h.stemMax)
                break;
            // Light hinting moves stems, it does not reshape them: the width
            // stays as designed, at least a pixel.
            const width = (top.y - bottom.y) * h.yScale;
            const w = width < 1 ? 1.0 : width;
            if (bottom.fitted && !top.fitted)
                top.target = bottom.target + w;
            else if (top.fitted && !bottom.fitted)
                bottom.target = top.target - w;
            else if (!top.fitted && !bottom.fitted)
            {
                const centre = (bottom.y + top.y) * 0.5 * h.yScale;
                bottom.target = roundPx(centre - w * 0.5);
                top.target = bottom.target + w;
            }
            bottom.fitted = top.fitted = true;
            break;
        }
    }
    // Everything else to its nearest row, in order.
    foreach (i, ref e; edges)
    {
        if (!e.fitted)
            e.target = roundPx(e.y * h.yScale);
        if (i && e.target < edges[i - 1].target)
            e.target = edges[i - 1].target;
    }
}
