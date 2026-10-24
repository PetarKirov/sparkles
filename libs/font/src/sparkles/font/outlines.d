/**
Glyph outlines (`docs/specs/font/SPEC.md` § 10, FTO1–FTO5, FTI6).

`glyphOutline` decodes a glyph of an instance into caller-owned segments;
`drawGlyph` drives any sink with `moveTo`, `lineTo`, `quadTo` and `close`
(and `cubicTo` when it has one) with the same segments. Coordinates are
font units, y-up, unscaled (FTO3), held as counts of 1/65,536 unit so
variation deltas keep their precision. TrueType `glyf` glyphs — simple,
composite (depth 8, at most 512 components, FTB3) and `gvar`-varied,
phantom points included — and `CFF`/`CFF2` Type 2 charstrings (subroutine
depth 10, at most 65,536 operations; `CFF2` blends weighed by the variation
store; `seac` accents) are decoded. A composite glyph or subroutine that
refers back to itself is a `cycle` error (FTB5).

Decoding writes points into an `OutlineWorkspace` the caller owns (FTA4)
and never allocates (FTB4). At the default instance no `gvar` bytes are
read (FTM14). The segment kinds never depend on coordinates (FTO4): every
contour closes with a line back to its start, even a zero-length one,
unless its last segment is a `glyf` curve that ends there by construction,
and a subpath that draws nothing emits nothing.
*/
module sparkles.font.outlines;

import sparkles.font.bytes : be16, be32, bes16, bes32, fits;
import sparkles.font.cff_outlines : cffOutline, cffOutlineSink;
import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontLimit,
    FontResult, fontErr, fontLimitValue, fontOk, limitError, Tag, tableError;
import sparkles.font.face : Face, OutlineFormat;
import sparkles.font.instance : Instance;
import sparkles.font.tables : head, hmtx, locate;
import sparkles.font.units : DesignValue;
import sparkles.font.variations : allZero;
import sparkles.font.vertical : vmtx;

import core.checkedint : muls;

// ---------------------------------------------------------------------------
// Writer-generic templates, declared before the attribute label so their
// attributes infer from the sink: one may allocate, throw or be impure (FTO1).
// ---------------------------------------------------------------------------

/// Replays segments into a sink (FTO1); also the CFF interpreter's sink writer.
package struct SinkWriter(Sink)
{
    Sink* sink;
    size_t count;
    OutlinePoint current;
    OutlinePoint start;
    bool open;

    void put(OutlineSegment segment)
    {
        ++count;
        final switch (segment.kind)
        {
            case SegmentKind.moveTo:
                sink.moveTo(segment.end);
                current = start = segment.end;
                open = true;
                break;
            case SegmentKind.lineTo:
                sink.lineTo(segment.end);
                current = segment.end;
                break;
            case SegmentKind.quadTo:
                sink.quadTo(segment.control1, segment.end);
                current = segment.end;
                break;
            case SegmentKind.cubicTo:
                static if (__traits(hasMember, Sink, "cubicTo"))
                    sink.cubicTo(segment.control1, segment.control2, segment.end);
                else
                    cubicAsQuads(sink, current, segment);
                current = segment.end;
                break;
            case SegmentKind.close:
                sink.close();
                current = start;
                open = false;
                break;
        }
    }
}

/// Approximates a cubic by quadratics within 1/16 font unit (FTO1).
private void cubicAsQuads(Sink)(Sink* sink, OutlinePoint p0, OutlineSegment cubic)
{
    // Elevate the quadratic to cubic degree and bound the difference by
    // its control polygon. A midpoint-only comparison is always zero.
    import std.math : abs;

    OutlinePoint mid(OutlinePoint a, OutlinePoint b)
        => OutlinePoint((a.x + b.x) / 2, (a.y + b.y) / 2);

    const p1 = cubic.control1, p2 = cubic.control2, p3 = cubic.end;
    // The midpoint-matching quadratic control.
    const q = OutlinePoint(
        (3 * (p1.x + p2.x) - p0.x - p3.x) / 4,
        (3 * (p1.y + p2.y) - p0.y - p3.y) / 4);
    const error1 = abs(3 * p1.x - p0.x - 2 * q.x) + abs(3 * p1.y - p0.y - 2 * q.y);
    const error2 = abs(3 * p2.x - p3.x - 2 * q.x) + abs(3 * p2.y - p3.y - 2 * q.y);
    if (error1 <= 3 * 4_096 && error2 <= 3 * 4_096)
    {
        sink.quadTo(q, p3);
        return;
    }
    const a = mid(p0, p1), b = mid(p1, p2), c = mid(p2, p3);
    const d = mid(a, b), e = mid(b, c), f = mid(d, e);
    cubicAsQuads(sink, p0, OutlineSegment(SegmentKind.cubicTo, f, a, d));
    cubicAsQuads(sink, f, OutlineSegment(SegmentKind.cubicTo, p3, e, c));
}

/**
Emits one `glyf` contour. Which segments appear depends only on the
on-curve flags and the point count, never on coordinates (FTO4): a
contour of one point draws nothing (as `hb_font_draw_glyph` omits a lone
move), and one whose last segment ends on an on-curve point closes with a
line back to its start, even when that line has zero length.
*/
private void emitContour(W)(scope const(OutlinePoint)[] pts, scope const(bool)[] on,
    ref W writer)
{
    const n = pts.length;
    if (n < 2)
        return;
    // Start on an on-curve point, or on the midpoint of two off-curve ones;
    // `remaining` points then follow cyclically from `index`.
    OutlinePoint start;
    size_t index, remaining;
    if (on[0])
    {
        start = pts[0];
        index = 1;
        remaining = n - 1;
    }
    else if (on[n - 1])
    {
        start = pts[n - 1];
        remaining = n - 1;
    }
    else
    {
        start = midpoint(pts[0], pts[n - 1]);
        remaining = n;
    }
    writer.put(OutlineSegment(SegmentKind.moveTo, start));
    bool endsAtStart; // the last segment is a curve back to the start
    while (remaining > 0)
    {
        const p = pts[index % n];
        if (on[index % n])
        {
            writer.put(OutlineSegment(SegmentKind.lineTo, p));
            ++index;
            --remaining;
            continue;
        }
        // An off-curve point: the curve ends at the next on-curve point,
        // at the implied midpoint, or, for the last point, at the start.
        const next = (index + 1) % n;
        const ending = remaining == 1;
        const end = ending ? start : on[next] ? pts[next] : midpoint(p, pts[next]);
        writer.put(OutlineSegment(SegmentKind.quadTo, end, p));
        endsAtStart = ending;
        const step = !ending && on[next] ? 2 : 1;
        index += step;
        remaining -= step;
    }
    if (!endsAtStart)
        writer.put(OutlineSegment(SegmentKind.lineTo, start));
    writer.put(OutlineSegment(SegmentKind.close));
}

/**
Drives `sink` with glyph `gid`'s outline (FTO1): `moveTo`, `lineTo`,
`quadTo` and `close`, plus `cubicTo` when the sink provides it; otherwise
cubics arrive as quadratics within 1/16 font unit. A sink with
`begin(size_t contourCount)` first learns how many contours it will
receive, which for `CFF` costs a counting pass over the charstring.
Otherwise the costs are `glyphOutline`'s. The
attributes infer from the sink's, so a sink may allocate, throw or be
impure; decoding itself never allocates.
*/
FontResult!GlyphOutline drawGlyph(Sink)(in Instance inst, uint gid,
    return scope OutlineWorkspace ws, ref Sink sink)
{
    enum hasBegin = __traits(hasMember, Sink, "begin");
    if (inst.face.outlines == OutlineFormat.cff)
    {
        static if (hasBegin)
        {
            SegmentWriter counter; // no buffer: counts only
            const counted = cffOutline(inst, gid, counter);
            if (counted.hasError)
                return counted;
            sink.begin(counted.value.contourCount);
        }
        return cffOutlineSink(inst, gid, sink);
    }
    // Expand points, then emit segments into the sink writer.
    const face = inst.face;
    auto tables = glyfTables(face);
    if (tables.hasError)
        return fontErr!GlyphOutline(tables.error);
    if (!tables.value.present)
        return fontErr!GlyphOutline(FontError(FontErrorKind.missingTable, glyfTag));
    Expander e;
    e.face = face;
    e.inst = inst;
    e.tables = tables.value;
    e.ws = ws;
    const expanded = expandGlyph(e, gid, Transform.init, 0, null);
    if (expanded.hasError)
        return fontErr!GlyphOutline(expanded.error);
    GlyphOutline result;
    result.pointCount = e.pointCount;
    result.contourCount = e.contourCount;
    result.overlap = e.overlap;
    result.empty = e.pointCount == 0;
    attachPhantom(e.phantom, ws, e.pointCount, result);
    static if (hasBegin)
        sink.begin(drawnContours(ws.contourEnds[0 .. e.contourCount]));
    SinkWriter!Sink writer;
    writer.sink = writerPtr(sink);
    size_t contourStart;
    foreach (c; 0 .. e.contourCount)
    {
        const contourEnd = ws.contourEnds[c];
        emitContour(ws.points[contourStart .. contourEnd + 1],
            ws.onCurve[contourStart .. contourEnd + 1], writer);
        contourStart = contourEnd + 1;
    }
    result.segmentCount = writer.count;
    return fontOk(result);
}

@safe pure nothrow @nogc:

private enum glyfTag = Tag("glyf"), locaTag = Tag("loca"), gvarTag = Tag("gvar"),
    cffTag = Tag("CFF ");

/**
The points a `PointWorkspace` holds: every point of a well-formed glyph,
whose point numbers are 16-bit.
*/
enum maxWorkspacePoints = 65_536;

/// A point in font units, y-up, as counts of 1/65,536 unit (FTO3).
struct OutlinePoint
{
    @safe pure nothrow @nogc:

    /// Counts of 1/65,536 font unit.
    long x, y;

    /// The point at whole font units `(x, y)`.
    static OutlinePoint fromUnits(int x, int y) => OutlinePoint(long(x) << 16, long(y) << 16);

    /// The coordinates in font units.
    double xUnits() const => x / 65_536.0;
    /// ditto
    double yUnits() const => y / 65_536.0;
}

/// What one segment of an outline does (FTO2).
enum SegmentKind : ubyte
{
    moveTo,
    lineTo,
    quadTo,
    cubicTo,
    close,
}

/**
One outline segment (FTO2). `end` is the segment's end point; a quadratic
segment's control point is `control1`, a cubic's are `control1` and
`control2`. A `close` segment carries no points.
*/
struct OutlineSegment
{
    @safe pure nothrow @nogc:

    SegmentKind kind;
    OutlinePoint end;
    OutlinePoint control1;
    OutlinePoint control2;
}

/// Caller-owned point storage for outline decoding (FTA4).
struct OutlineWorkspace
{
    @safe pure nothrow @nogc:

    /// Decoded outline points, in glyph order, phantom points excluded.
    OutlinePoint[] points;
    /// Whether `points[i]` lies on the curve (`glyf`; all true for `CFF`).
    bool[] onCurve;
    /// The last point index of each contour.
    ushort[] contourEnds;
    /**
    Scratch for a `gvar` tuple that lists its points (FTO4): one entry per
    listed point, so as long as a varied glyph's points plus its four
    phantom points. A shorter array is `limitExceeded` naming
    `callerStorage` with the length a glyph needs; `CFF` and default
    instances never touch it.
    */
    uint[] pointNumbers;
    /// ditto
    int[] deltaX, deltaY;
    /// ditto
    int[2][] referenced;
}

/**
Storage for every point of one glyph and its `gvar` scratch, about
2.6 MiB: what the point lookups (`glyphPoint`, `phantomAdvance`,
`glyphBounds`) and the metrics built on them decode into. It is too large
for a stack, so hold it in a `sparkles.base.unique.Unique` made once,
where the caller sets up, and pass it to each lookup; the lookups
themselves never allocate (FTB4).
*/
struct PointWorkspace
{
    @safe pure nothrow @nogc:

    OutlinePoint[maxWorkspacePoints] points;
    bool[maxWorkspacePoints] onCurve;
    ushort[maxWorkspacePoints] contourEnds;
    uint[maxWorkspacePoints + 4] pointNumbers;
    int[maxWorkspacePoints + 4] deltaX, deltaY;
    int[2][maxWorkspacePoints + 4] referenced;

    /// The workspace as the outline decoder's workspace.
    OutlineWorkspace outline() return
        => OutlineWorkspace(points[], onCurve[], contourEnds[], pointNumbers[], deltaX[], deltaY[],
            referenced[]);
}

/// What decoding one glyph found, beside its segments (FTO2, FTO5).
struct GlyphOutline
{
    @safe pure nothrow @nogc:

    /// Segments written (or that would be written, on a counting pass).
    size_t segmentCount;
    /// Outline points decoded, phantom points excluded.
    size_t pointCount;
    /// Contours decoded.
    size_t contourCount;
    /// Whether the glyph has no outline (a space, an empty `glyf` entry).
    bool empty;
    /// Whether the glyph's data flags overlapping contours (FTI6).
    bool overlap;
    /// Whether `phantom` holds the four `glyf` phantom points (FTO5).
    bool hasPhantom;
    /**
    The phantom points after variation: origin, horizontal advance point,
    vertical origin, vertical advance point. In a face without `HVAR` the
    horizontal advance at the instance is `(phantom[1].x - phantom[0].x)`.
    */
    OutlinePoint[4] phantom;
}

// ---------------------------------------------------------------------------
// Segment output: an array (FTO2) or a sink (FTO1)
// ---------------------------------------------------------------------------

/**
The address of a writer that outlives the synchronous call using it: the
one operation `@safe` code cannot express, wrapped in a `@trusted` lambda.
*/
package W* writerPtr(W)(ref W writer) => (() @trusted => &writer)();

/// Writes segments into the caller's array, counting past its end (FTO2).
package struct SegmentWriter
{
    @safe pure nothrow @nogc:

    OutlineSegment[] buffer;
    size_t count;

    void put(OutlineSegment segment)
    {
        if (count < buffer.length)
            buffer[count] = segment;
        ++count;
    }
}

// ---------------------------------------------------------------------------
// glyf / loca
// ---------------------------------------------------------------------------

private struct GlyfTables
{
    const(ubyte)[] glyf;
    ulong glyfStart;
    const(ubyte)[] loca;
    ulong locaStart;
    short locFormat;
    bool present;
}

private FontResult!GlyfTables glyfTables(return scope const Face face)
{
    if (!face.has(glyfTag))
        return fontOk(GlyfTables.init);
    auto g = locate(face, glyfTag);
    if (g.hasError)
        return fontErr!GlyfTables(g.error);
    auto l = locate(face, locaTag);
    if (l.hasError)
        return fontErr!GlyfTables(l.error);
    auto h = head(face);
    if (h.hasError)
        return fontErr!GlyfTables(h.error);
    if (h.value.indexToLocFormat != 0 && h.value.indexToLocFormat != 1)
        return fontErr!GlyfTables(tableError(FontErrorKind.badValue, Tag("head"),
            face.record(face.find(Tag("head"))).offset, 50));
    return fontOk(GlyfTables(g.value.data, g.value.start, l.value.data, l.value.start,
        h.value.indexToLocFormat, true));
}

private FontResult!uint glyphOffset(in GlyfTables t, uint gid)
{
    if (t.locFormat == 0)
    {
        const at = 2UL * gid;
        if (!fits(t.loca.length, at, 2))
            return fontErr!uint(tableError(FontErrorKind.truncated, locaTag, t.locaStart, at));
        return fontOk!uint(2u * be16(t.loca, cast(size_t) at));
    }
    const at = 4UL * gid;
    if (!fits(t.loca.length, at, 4))
        return fontErr!uint(tableError(FontErrorKind.truncated, locaTag, t.locaStart, at));
    return fontOk(be32(t.loca, cast(size_t) at));
}

private struct GlyphRange
{
    size_t begin, end; // inside glyf
    bool empty;
    short contours;
    short xMin, yMin, xMax, yMax;
}

private FontResult!GlyphRange glyphRange(in GlyfTables t, uint gid, uint numGlyphs)
{
    if (gid >= numGlyphs)
        return fontErr!GlyphRange(FontError(FontErrorKind.indexOutOfRange, glyfTag));
    const first = glyphOffset(t, gid);
    if (first.hasError)
        return fontErr!GlyphRange(first.error);
    const next = glyphOffset(t, gid + 1);
    if (next.hasError)
        return fontErr!GlyphRange(next.error);
    if (next.value < first.value)
        return fontErr!GlyphRange(tableError(FontErrorKind.badValue, locaTag, t.locaStart, 0));
    GlyphRange r;
    r.begin = first.value;
    r.end = next.value;
    if (first.value == next.value)
    {
        r.empty = true;
        return fontOk(r);
    }
    if (!fits(t.glyf.length, r.begin, 10))
        return fontErr!GlyphRange(tableError(FontErrorKind.truncated, glyfTag, t.glyfStart, r.begin));
    const d = t.glyf;
    const p = r.begin;
    r.contours = bes16(d, p);
    r.xMin = bes16(d, p + 2);
    r.yMin = bes16(d, p + 4);
    r.xMax = bes16(d, p + 6);
    r.yMax = bes16(d, p + 8);
    if (!fits(d.length, r.begin, r.end - r.begin))
        return fontErr!GlyphRange(tableError(FontErrorKind.badValue, glyfTag, t.glyfStart, r.begin));
    return fontOk(r);
}

// ---------------------------------------------------------------------------
// Point expansion
// ---------------------------------------------------------------------------

private struct Transform
{
    @safe pure nothrow @nogc:

    // F2Dot14 matrix, identity by default.
    int xx = 16_384, yx = 0, xy = 0, yy = 16_384;
    long dx, dy; // raw (1/65,536) translation

    bool isIdentity() const => xx == 16_384 && yy == 16_384 && yx == 0 && xy == 0
        && dx == 0 && dy == 0;

    /// The linear part applied to `p`, without the translation.
    OutlinePoint linear(OutlinePoint p) const
        => OutlinePoint((p.x * xx + p.y * xy + 8_192) >> 14,
            (p.x * yx + p.y * yy + 8_192) >> 14);

    OutlinePoint apply(OutlinePoint p) const
    {
        const r = linear(p);
        return OutlinePoint(r.x + dx, r.y + dy);
    }

    /// `this ∘ inner`: applies `inner` first, then this transform.
    Transform after(Transform inner) const
    {
        Transform r;
        r.xx = cast(int)((long(xx) * inner.xx + long(xy) * inner.yx + 8_192) >> 14);
        r.xy = cast(int)((long(xx) * inner.xy + long(xy) * inner.yy + 8_192) >> 14);
        r.yx = cast(int)((long(yx) * inner.xx + long(yy) * inner.yx + 8_192) >> 14);
        r.yy = cast(int)((long(yx) * inner.xy + long(yy) * inner.yy + 8_192) >> 14);
        const t = linear(OutlinePoint(inner.dx, inner.dy));
        r.dx = t.x + dx;
        r.dy = t.y + dy;
        return r;
    }
}

private struct Expander
{
    @safe pure nothrow @nogc:

    Face face;
    Instance inst;
    OutlinePoint[4] phantom;
    bool requireMetrics = true;
    GlyfTables tables;
    OutlineWorkspace ws;
    size_t pointCount;
    size_t contourCount;
    bool overlap;
    uint components;

    FontResult!bool appendPoint(OutlinePoint p, bool onCurve, Tag tag, ulong at)
    {
        if (pointCount >= ws.points.length || pointCount >= ws.onCurve.length)
            return fontErr!bool(callerStorageError(pointCount + 1, tag, at));
        ws.points[pointCount] = p;
        ws.onCurve[pointCount] = onCurve;
        ++pointCount;
        return fontOk(true);
    }
}

/**
The four phantom points of glyph `gid` before variation, placed as HarfBuzz
places them: the horizontal pair from `hmtx`'s left side bearing and
advance, the vertical pair from `vmtx`'s top side bearing and advance
height. Without a usable `vmtx` entry the bearing is 0 and the advance
`unitsPerEm`, HarfBuzz's defaults.
*/
private FontResult!(OutlinePoint[4]) storedPhantom(in Expander e, uint gid, GlyphRange range)
{
    OutlinePoint[4] points;
    int topBearing = 0, advanceHeight = e.face.unitsPerEm;
    const vertical = vmtx(e.face);
    if (vertical.hasValue)
    {
        const tsb = vertical.value.topSideBearing(gid);
        if (tsb.hasValue)
            topBearing = tsb.value;
        const advance = vertical.value.advance(gid);
        if (advance.hasValue)
            advanceHeight = advance.value;
    }
    const top = (range.empty ? 0 : range.yMax) + topBearing;
    points[2] = OutlinePoint.fromUnits(0, top);
    points[3] = OutlinePoint.fromUnits(0, top - advanceHeight);
    const metrics = hmtx(e.face);
    if (metrics.hasError)
        return e.requireMetrics ? fontErr!(OutlinePoint[4])(metrics.error) : fontOk(points);
    const metric = metrics.value.metric(gid);
    if (metric.hasError)
        return e.requireMetrics ? fontErr!(OutlinePoint[4])(metric.error) : fontOk(points);
    const origin = range.empty ? 0 : range.xMin - metric.value.lsb;
    points[0] = OutlinePoint.fromUnits(origin, 0);
    points[1] = OutlinePoint.fromUnits(origin + metric.value.advanceWidth, 0);
    return fontOk(points);
}

/// Varies each glyph in its own coordinate system, then applies its placement.
private FontResult!bool expandGlyph(ref Expander e, uint gid, Transform transform, uint depth,
    scope const(uint)[] ancestors)
{
    const t = e.tables;
    const range = glyphRange(t, gid, e.face.numGlyphs);
    if (range.hasError)
        return fontErr!bool(range.error);
    foreach (a; ancestors)
        if (a == gid)
            return fontErr!bool(FontError(FontErrorKind.cycle, glyfTag,
                e.tables.glyfStart + range.value.begin));
    if (depth > fontLimitValue[FontLimit.compositeDepth])
        return fontErr!bool(limitError(FontLimit.compositeDepth, glyfTag,
            t.glyfStart + range.value.begin));

    auto phantoms = storedPhantom(e, gid, range.value);
    if (phantoms.hasError)
        return fontErr!bool(phantoms.error);
    auto phantom = phantoms.value;
    if (!range.value.empty && range.value.contours < 0)
        return expandComposite(e, range.value, transform, depth, ancestors, gid, phantom);

    const pointsBefore = e.pointCount;
    if (!range.value.empty)
    {
        const expanded = expandSimple(e, range.value, Transform.init);
        if (expanded.hasError)
            return expanded;
    }
    const varied = applyGvar(e.face, e.inst, gid, e.ws.points[pointsBefore .. e.pointCount], phantom[],
        e.ws);
    if (varied.hasError)
        return varied;
    if (!transform.isIdentity)
    {
        foreach (ref point; e.ws.points[pointsBefore .. e.pointCount])
            point = transform.apply(point);
    }
    e.phantom = phantom;
    return fontOk(true);
}

private FontResult!bool expandSimple(ref Expander e, GlyphRange range, Transform transform)
{
    const d = e.tables.glyf;
    const begin = range.begin;
    const contourCount = cast(size_t) range.contours;
    const endsAt = begin + 10;
    if (!fits(d.length, endsAt, 2UL * contourCount))
        return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag, e.tables.glyfStart, endsAt));
    if (contourCount == 0)
        return fontOk(true);
    const pointTotal = cast(size_t) be16(d, endsAt + 2 * (contourCount - 1)) + 1;
    size_t at = endsAt + 2 * contourCount;
    if (!fits(d.length, at, 2))
        return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag, e.tables.glyfStart, at));
    at += 2 + be16(d, at); // instructions
    if (at > range.end)
        return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag, e.tables.glyfStart, at));

    const pointsBefore = e.pointCount;
    const flagStart = at;
    // Pass 1: walk the flag stream to find where the coordinates start.
    size_t coordAt = at;
    {
        size_t produced;
        while (produced < pointTotal)
        {
            if (coordAt >= range.end)
                return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag,
                    e.tables.glyfStart, coordAt));
            const flag = d[coordAt++];
            if (flag & 0x40)
                e.overlap = true;
            size_t n = 1;
            if (flag & 0x08)
            {
                if (coordAt >= range.end)
                    return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag,
                        e.tables.glyfStart, coordAt));
                n += d[coordAt++];
            }
            produced += n;
            if (produced > pointTotal)
                return fontErr!bool(tableError(FontErrorKind.badValue, glyfTag,
                    e.tables.glyfStart, flagStart));
        }
    }
    if (e.pointCount + pointTotal > e.ws.points.length
        || e.pointCount + pointTotal > e.ws.onCurve.length)
        return fontErr!bool(callerStorageError(e.pointCount + pointTotal, glyfTag,
            e.tables.glyfStart + begin));
    // Pass 2: append points (on-curve flags), coordinates filled below.
    {
        size_t fAt = flagStart;
        size_t idx;
        while (idx < pointTotal)
        {
            const flag = d[fAt++];
            size_t n = 1;
            if (flag & 0x08)
                n += d[fAt++];
            foreach (_; 0 .. n)
            {
                const appended = e.appendPoint(OutlinePoint.init, (flag & 0x01) != 0,
                    glyfTag, e.tables.glyfStart + begin);
                if (appended.hasError)
                    return appended;
                ++idx;
            }
        }
    }
    // Pass 3: the x-coordinate stream, then the y stream, each in flag order.
    size_t readAt = coordAt;
    foreach (axis; 0 .. 2)
    {
        const shortBit = axis == 0 ? 0x02 : 0x04;
        const sameBit = axis == 0 ? 0x10 : 0x20;
        long coord;
        size_t pointIndex = pointsBefore;
        size_t fAt = flagStart;
        size_t remaining = pointTotal;
        while (remaining > 0)
        {
            const flag = d[fAt++];
            size_t n = 1;
            if (flag & 0x08)
                n += d[fAt++];
            foreach (_; 0 .. n)
            {
                if (flag & shortBit)
                {
                    if (readAt >= range.end)
                        return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag,
                            e.tables.glyfStart, readAt));
                    const v = d[readAt++];
                    coord += (flag & sameBit) ? v : -v;
                }
                else if (!(flag & sameBit))
                {
                    if (readAt + 2 > range.end)
                        return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag,
                            e.tables.glyfStart, readAt));
                    coord += bes16(d, readAt);
                    readAt += 2;
                }
                if (axis == 0)
                    e.ws.points[pointIndex].x = coord << 16;
                else
                    e.ws.points[pointIndex].y = coord << 16;
                ++pointIndex;
                --remaining;
            }
        }
    }
    foreach (i; pointsBefore .. e.pointCount)
        if (!transform.isIdentity)
            e.ws.points[i] = transform.apply(e.ws.points[i]);
    foreach (c; 0 .. contourCount)
    {
        const end = pointsBefore + be16(d, endsAt + 2 * c);
        // Composite point numbers, and `maxp.maxCompositePoints`, are
        // 16-bit: a glyph past 65,535 points is malformed.
        if (end > ushort.max)
            return fontErr!bool(tableError(FontErrorKind.badValue, glyfTag,
                e.tables.glyfStart, endsAt + 2 * c));
        if (c > 0 && end <= e.ws.contourEnds[e.contourCount - 1])
            return fontErr!bool(tableError(FontErrorKind.badValue, glyfTag,
                e.tables.glyfStart, endsAt + 2 * c));
        if (e.contourCount >= e.ws.contourEnds.length)
            return fontErr!bool(callerStorageError(e.contourCount + 1, glyfTag,
                e.tables.glyfStart + begin));
        e.ws.contourEnds[e.contourCount++] = cast(ushort) end;
    }
    return fontOk(true);
}

private FontResult!bool expandComposite(ref Expander e, GlyphRange range, Transform transform,
    uint depth, scope const(uint)[] ancestors, uint gid, ref OutlinePoint[4] phantom)
{
    const d = e.tables.glyf;
    // gvar numbers a composite's components, not the points in their outlines.
    OutlinePoint[512] placements;
    size_t componentCount;
    size_t scan = range.begin + 10;
    bool scanning = true;
    while (scanning)
    {
        if (!fits(range.end, scan, 4))
            return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag, e.tables.glyfStart, scan));
        const flags = be16(d, scan);
        const length = 4 + ((flags & 1) ? 4 : 2)
            + ((flags & 8) ? 2 : (flags & 64) ? 4 : (flags & 128) ? 8 : 0);
        if (!fits(range.end, scan, length))
            return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag, e.tables.glyfStart, scan));
        scan += length;
        if (++componentCount > placements.length)
            return fontErr!bool(limitError(FontLimit.compositeComponents, glyfTag,
                e.tables.glyfStart + range.begin));
        scanning = (flags & 0x20) != 0;
    }
    const varied = applyGvar(e.face, e.inst, gid, placements[0 .. componentCount], phantom[], e.ws);
    if (varied.hasError)
        return varied;
    size_t componentIndex;
    const compositeStart = e.pointCount;
    size_t at = range.begin + 10;
    uint[16] chain;
    chain[0 .. ancestors.length] = ancestors[];
    chain[ancestors.length] = gid;
    const chainLength = ancestors.length + 1;
    bool more = true;
    while (more)
    {
        if (!fits(d.length, at, 4) || at + 4 > range.end)
            return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag, e.tables.glyfStart, at));
        const flags = be16(d, at);
        const component = be16(d, at + 2);
        at += 4;
        if (flags & 0x0400) // OVERLAP_COMPOUND
            e.overlap = true;
        if (++e.components > fontLimitValue[FontLimit.compositeComponents])
            return fontErr!bool(limitError(FontLimit.compositeComponents, glyfTag,
                e.tables.glyfStart + range.begin));
        // XY offsets are signed; point numbers are unsigned.
        const xyValues = (flags & 0x0002) != 0;
        int arg1, arg2;
        if (flags & 0x0001)
        {
            if (!fits(d.length, at, 4) || at + 4 > range.end)
                return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag,
                    e.tables.glyfStart, at));
            arg1 = xyValues ? bes16(d, at) : be16(d, at);
            arg2 = xyValues ? bes16(d, at + 2) : be16(d, at + 2);
            at += 4;
        }
        else
        {
            if (!fits(d.length, at, 2) || at + 2 > range.end)
                return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag,
                    e.tables.glyfStart, at));
            arg1 = xyValues ? cast(byte) d[at] : d[at];
            arg2 = xyValues ? cast(byte) d[at + 1] : d[at + 1];
            at += 2;
        }
        Transform local;
        if (flags & 0x0008)
        {
            if (!fits(d.length, at, 2))
                return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag,
                    e.tables.glyfStart, at));
            local.xx = local.yy = bes16(d, at);
            at += 2;
        }
        else if (flags & 0x0040)
        {
            if (!fits(d.length, at, 4))
                return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag,
                    e.tables.glyfStart, at));
            local.xx = bes16(d, at);
            local.yy = bes16(d, at + 2);
            at += 4;
        }
        else if (flags & 0x0080)
        {
            if (!fits(d.length, at, 8))
                return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag,
                    e.tables.glyfStart, at));
            local.xx = bes16(d, at);
            local.yx = bes16(d, at + 2);
            local.xy = bes16(d, at + 4);
            local.yy = bes16(d, at + 6);
            at += 8;
        }
        // F2Dot14 fields are stored as signed 2.14 in a short: reuse raw.
        local.xx = cast(short) local.xx;
        local.yy = cast(short) local.yy;
        local.yx = cast(short) local.yx;
        local.xy = cast(short) local.xy;
        const pointsBefore = e.pointCount;
        const sub = expandGlyph(e, component, transform.after(local), depth + 1,
            chain[0 .. chainLength]);
        if (sub.hasError)
            return sub;
        // Position the component: an XY shift is stated in this glyph's
        // space, so it passes through the outer transform's linear part.
        if (!xyValues)
        {
            // arg1 numbers this composite's points placed so far, arg2
            // the component's own points.
            if (compositeStart + cast(size_t) arg1 >= pointsBefore
                || pointsBefore + cast(size_t) arg2 >= e.pointCount)
                return fontErr!bool(FontError(FontErrorKind.badValue, glyfTag,
                    e.tables.glyfStart + range.begin));
            const anchor = e.ws.points[compositeStart + arg1];
            const moved = e.ws.points[pointsBefore + arg2];
            const shiftX = anchor.x - moved.x;
            const shiftY = anchor.y - moved.y;
            foreach (i; pointsBefore .. e.pointCount)
            {
                e.ws.points[i].x += shiftX;
                e.ws.points[i].y += shiftY;
            }
        }
        else
        {
            auto shift = OutlinePoint((long(arg1) << 16) + placements[componentIndex].x,
                (long(arg2) << 16) + placements[componentIndex].y);
            // ROUND_XY_TO_GRID is a hinted pixel-grid operation, not a
            // rounding of unscaled design-space variation deltas.
            // SCALED_COMPONENT_OFFSET without UNSCALED_COMPONENT_OFFSET
            // passes the offset through the component's own matrix, as
            // HarfBuzz and FreeType do; the default is unscaled.
            if ((flags & 0x1800) == 0x0800)
                shift = local.linear(shift);
            const moved = transform.linear(shift);
            foreach (i; pointsBefore .. e.pointCount)
            {
                e.ws.points[i].x += moved.x;
                e.ws.points[i].y += moved.y;
            }
        }
        // Metrics are inherited before component scaling/placement, as in
        // HarfBuzz: component placement must not shift the glyph origin.
        if (flags & 0x0200)
            phantom = e.phantom;
        ++componentIndex;
        more = (flags & 0x0020) != 0;
    }
    e.phantom = phantom;
    // A composite's own instructions follow the last component.
    return fontOk(true);
}

// ---------------------------------------------------------------------------
// gvar
// ---------------------------------------------------------------------------

private enum long tupleScalarOne = 1L << 30;

private long tentScalar(short coord, short peak, short start, short end, bool intermediate)
{
    // Keep 30 fractional bits: rounding axis products to F2Dot14 loses
    // visible precision on large outlines and multi-axis tuples.
    if (peak == 0 || coord == peak)
        return tupleScalarOne;
    if (!intermediate)
    {
        if (coord == 0 || (coord < 0) != (peak < 0))
            return 0;
        if (coord < 0 ? coord <= peak : coord >= peak)
            return tupleScalarOne;
        return long(coord) * tupleScalarOne / peak;
    }
    if (start > peak || peak > end || start < 0 && end > 0)
        return tupleScalarOne;
    if (coord <= start || coord >= end)
        return 0;
    if (coord < peak)
        return long(coord - start) * tupleScalarOne / (peak - start);
    return long(end - coord) * tupleScalarOne / (end - peak);
}

/// Applies `gvar` deltas to the expanded points and phantom points of `gid`.
/// One `gvar` tuple's placement, gathered while walking its headers.
/// One tuple's weight at the instance and where its x delta series starts.
private struct TupleInfoData
{
    long scalar; // 30 fractional bits
    size_t pointDataAt;
}

private FontResult!bool applyGvar(scope const Face face, in Instance inst, uint gid,
    scope OutlinePoint[] points, scope OutlinePoint[] phantom, scope OutlineWorkspace ws)
{
    if (inst.allZero)
        return fontOk(true);
    auto at = locate(face, gvarTag);
    if (at.hasError)
    {
        if (at.error.kind == FontErrorKind.missingTable)
            return fontOk(true);
        return fontErr!bool(at.error);
    }
    const d = at.value.data;
    const start = at.value.start;
    if (d.length < 20)
        return fontErr!bool(tableError(FontErrorKind.truncated, gvarTag, start, d.length));
    if (be16(d, 0) != 1)
        return fontErr!bool(tableError(FontErrorKind.unsupportedVersion, gvarTag, start, 0));
    const axisCount = be16(d, 4);
    if (axisCount != inst.axisCount || axisCount > 64)
        return fontErr!bool(tableError(FontErrorKind.badValue, gvarTag, start, 4));
    const sharedCount = be16(d, 6);
    const sharedAt = be32(d, 8);
    const glyphCount = be16(d, 12);
    const longOffsets = (be16(d, 14) & 1) != 0;
    const dataArrayAt = be32(d, 16);
    if (gid >= glyphCount && glyphCount != 0 && gid >= face.numGlyphs)
        return fontOk(true);
    const offsetSize = longOffsets ? 4 : 2;
    size_t offsetsAt = 20;
    if (!fits(d.length, offsetsAt, offsetSize * (ulong(glyphCount) + 1)))
        return fontErr!bool(tableError(FontErrorKind.truncated, gvarTag, start, offsetsAt));
    uint glyphOffset(uint i)
        => longOffsets ? be32(d, offsetsAt + 4UL * i) : 2u * be16(d, offsetsAt + 2UL * i);
    if (gid + 1 > glyphCount)
        return fontOk(true);
    const begin = glyphOffset(gid), end = glyphOffset(gid + 1);
    if (begin == end)
        return fontOk(true);
    const base = ulong(dataArrayAt) + begin;
    if (!fits(d.length, base, 4) || !fits(d.length, base, end - begin))
        return fontErr!bool(tableError(FontErrorKind.truncated, gvarTag, start, base));
    const header = be16(d, cast(size_t) base);
    const tupleCount = header & 0x0FFF; // 0x8000 is SHARED_POINT_NUMBERS; 0x7000 is reserved
    const sharedPoints = (header & 0x8000) != 0;
    const dataAt = base + be16(d, cast(size_t) base + 2);
    const glyphEnd = base + (end - begin);
    if (dataAt > glyphEnd)
        return fontErr!bool(tableError(FontErrorKind.badOffset, gvarTag, start, base + 2));

    const totalPoints = points.length + phantom.length;
    // Shared tuple peaks.
    if (!fits(d.length, sharedAt, 2UL * axisCount * sharedCount))
        return fontErr!bool(tableError(FontErrorKind.truncated, gvarTag, start, sharedAt));

    // Shared point numbers begin the serialized data, not the headers.
    const allPoints = PointList(true, 0, null, 0, totalPoints, true);
    const sharedList = sharedPoints
        ? parsePointNumbers(d, cast(size_t) dataAt, totalPoints, start, glyphEnd) : fontOk!PointList(allPoints);
    if (sharedList.hasError)
        return fontErr!bool(sharedList.error);
    const shared_ = sharedList.value;

    // Each tuple's serialized data is the next variationDataSize bytes
    // (its header's first field), whatever the deltas inside it parse to.
    size_t dataCursor = cast(size_t) dataAt + shared_.consumed;
    size_t headerAt = cast(size_t)(base + 4);
    foreach (ti; 0 .. tupleCount)
    {
        if (!fits(d.length, headerAt, 4))
            return fontErr!bool(tableError(FontErrorKind.truncated, gvarTag, start, headerAt));
        const tupleEnd = dataCursor + be16(d, headerAt);
        const flags = be16(d, headerAt + 2);
        if (tupleEnd > glyphEnd)
            return fontErr!bool(tableError(FontErrorKind.truncated, gvarTag, start, headerAt));
        size_t p = headerAt + 4;
        short[64] peak, istart, iend;
        if (flags & 0x8000)
        {
            if (!fits(d.length, p, 2UL * axisCount))
                return fontErr!bool(tableError(FontErrorKind.truncated, gvarTag, start, p));
            foreach (a; 0 .. axisCount)
                peak[a] = bes16(d, p + 2 * a);
            p += 2 * axisCount;
        }
        else
        {
            const index = flags & 0x0FFF;
            if (index >= sharedCount)
                return fontErr!bool(tableError(FontErrorKind.badValue, gvarTag, start, headerAt + 2));
            foreach (a; 0 .. axisCount)
                peak[a] = bes16(d, sharedAt + 2UL * (index * axisCount + a));
        }
        if (flags & 0x4000)
        {
            if (!fits(d.length, p, 4UL * axisCount))
                return fontErr!bool(tableError(FontErrorKind.truncated, gvarTag, start, p));
            foreach (a; 0 .. axisCount)
            {
                istart[a] = bes16(d, p + 2 * a);
                iend[a] = bes16(d, p + 2 * axisCount + 2 * a);
            }
            p += 4 * axisCount;
        }
        else
            foreach (a; 0 .. axisCount)
            {
                istart[a] = peak[a] < 0 ? peak[a] : 0;
                iend[a] = peak[a] > 0 ? peak[a] : 0;
            }
        // Scalar: product over axes of the tent factors.
        long scalar = tupleScalarOne;
        foreach (a; 0 .. axisCount)
        {
            if (peak[a] == 0)
                continue;
            const coord = a < inst.coords.length ? inst.coords[a] : cast(short) 0;
            scalar = scalar * tentScalar(coord, peak[a], istart[a], iend[a], (flags & 0x4000) != 0) / tupleScalarOne;
            if (scalar == 0)
                break;
        }
        if (scalar != 0)
        {
            const privatePoints = (flags & 0x2000) != 0;
            const list = privatePoints
                ? parsePointNumbers(d, dataCursor, totalPoints, start, tupleEnd) : fontOk!PointList(shared_);
            if (list.hasError)
                return fontErr!bool(list.error);
            const info = TupleInfoData(scalar, dataCursor + (privatePoints ? list.value.consumed : 0));
            const applied = applyTupleDeltas(face, gid, d, info, list.value, totalPoints, points, phantom,
                start, tupleEnd, ws);
            if (applied.hasError)
                return applied;
        }
        dataCursor = tupleEnd;
        headerAt = p;
    }
    return fontOk(true);
}

/// Applies one tuple's x and y delta series to points and phantom.
private FontResult!bool applyTupleDeltas(in Face face, uint gid,
    scope const(ubyte)[] d, in TupleInfoData info,
    in PointList list, size_t totalPoints, scope OutlinePoint[] points,
    scope OutlinePoint[] phantom, ulong start, ulong limit, scope OutlineWorkspace ws)
{
    if (!list.all && points.length)
        return applySparseTuple(face, gid, d, info, list, points, phantom, start, limit, ws);
    // Both series must lie inside the tuple's data before either applies.
    const count = listCount(list, totalPoints);
    const xEnd = skipDeltaSeries(d, info.pointDataAt, count, start, limit);
    if (xEnd.hasError)
        return fontErr!bool(xEnd.error);
    const yEnd = skipDeltaSeries(d, xEnd.value, count, start, limit);
    if (yEnd.hasError)
        return fontErr!bool(yEnd.error);
    const applied = applyDeltaSeries(d, info.pointDataAt, list, totalPoints, info.scalar, points, phantom,
        start, ws.pointNumbers);
    if (applied.hasError)
        return applied;
    return applyDeltaSeries(d, xEnd.value, list, totalPoints, info.scalar,
        points, phantom, start, ws.pointNumbers, true);
}

/// Replays validated simple-glyph coordinates without copying the whole outline.
/// This keeps IUP based on the stored points even after other tuples have applied.
private struct SimplePointReader
{
    @safe pure nothrow @nogc:

    const(ubyte)[] data, ends;
    size_t flagAt, xAt, yAt;
    size_t remaining;
    ubyte flag;
    long x, y;

    OutlinePoint next() scope
    {
        if (remaining == 0)
        {
            flag = data[flagAt++];
            remaining = (flag & 8) ? 1 + data[flagAt++] : 1;
        }
        --remaining;
        long delta(ref size_t at, uint shortBit, uint sameBit)
        {
            if (flag & shortBit)
            {
                const v = data[at++];
                return (flag & sameBit) ? v : -v;
            }
            if (flag & sameBit)
                return 0;
            const v = bes16(data, at);
            at += 2;
            return v;
        }
        x += delta(xAt, 2, 16);
        y += delta(yAt, 4, 32);
        return OutlinePoint(x << 16, y << 16);
    }
}

private FontResult!SimplePointReader simplePointReader(return scope const Face face, uint gid)
{
    const tables = glyfTables(face);
    if (tables.hasError)
        return fontErr!SimplePointReader(tables.error);
    const range = glyphRange(tables.value, gid, face.numGlyphs);
    if (range.hasError)
        return fontErr!SimplePointReader(range.error);
    SimplePointReader r;
    const g = range.value;
    if (g.empty || g.contours <= 0)
        return fontOk(r);
    // expandSimple has already validated these streams before gvar runs.
    r.data = tables.value.glyf[0 .. g.end];
    r.ends = r.data[g.begin + 10 .. g.begin + 10 + 2 * g.contours];
    const count = size_t(be16(r.ends, r.ends.length - 2)) + 1;
    const instructionsAt = g.begin + 10 + r.ends.length;
    r.flagAt = instructionsAt + 2 + be16(r.data, instructionsAt);
    size_t at = r.flagAt, produced, xBytes;
    while (produced < count)
    {
        const flag = r.data[at++];
        const n = (flag & 8) ? 1 + r.data[at++] : 1;
        xBytes += n * ((flag & 2) ? 1 : (flag & 16) ? 0 : 2);
        produced += n;
    }
    r.xAt = at;
    r.yAt = at + xBytes;
    return fontOk(r);
}

/**
The bytes per delta a packed-delta run's control byte declares: none for a
run of zeros (0x80), one, two (0x40), or four for 0xC0, which HarfBuzz and
fontTools read as 32-bit deltas.
*/
private uint deltaWidth(ubyte control) => control & 0x80 ? (control & 0x40 ? 4 : 0) : control & 0x40 ? 2 : 1;

/// The packed delta of `width` bytes at `at` (0 for a zero run).
private int packedDelta(scope const(ubyte)[] d, size_t at, uint width)
    => width == 4 ? bes32(d, at) : width == 2 ? bes16(d, at) : width == 1 ? cast(byte) d[at] : 0;

private FontResult!size_t readSparseDeltas(scope const(ubyte)[] d, size_t at,
    scope int[] values, ulong start, ulong limit)
{
    size_t written;
    while (written < values.length)
    {
        if (at >= d.length || at >= limit)
            return fontErr!size_t(tableError(FontErrorKind.truncated, gvarTag, start, at));
        const control = d[at++];
        const count = (control & 63) + 1;
        if (count > values.length - written)
            return fontErr!size_t(tableError(FontErrorKind.badValue, gvarTag, start, at - 1));
        const width = deltaWidth(control);
        foreach (_; 0 .. count)
        {
            if (!fits(d.length, at, width) || at + width > limit)
                return fontErr!size_t(tableError(FontErrorKind.truncated, gvarTag, start, at));
            values[written++] = packedDelta(d, at, width);
            at += width;
        }
    }
    return fontOk(at);
}

/**
An inferred delta, in 16.16 units, using the original axis coordinates;
exact unless the interpolation overflows 64 bits, which falls back to
floating point.
*/
private long inferredDelta(long coord, long a, long b, int da, int db)
{
    if (a == b)
        return da == db ? long(da) << 16 : 0;
    if (a > b)
        return inferredDelta(coord, b, a, db, da);
    if (coord <= a)
        return long(da) << 16;
    if (coord >= b)
        return long(db) << 16;
    bool overflow;
    const span = muls((long(db) - da) << 16, coord - a, overflow);
    if (!overflow)
        return (long(da) << 16) + span / (b - a);
    return (long(da) << 16) + cast(long)(double((long(db) - da) << 16) * (coord - a) / (b - a));
}

private FontResult!bool applySparseTuple(in Face face, uint gid, scope const(ubyte)[] d,
    in TupleInfoData info, in PointList list, scope OutlinePoint[] points,
    scope OutlinePoint[] phantom, ulong start, ulong limit, scope OutlineWorkspace ws)
{
    const parsed = decodePointList(list.data, 0, points.length + phantom.length, start,
        list.data.length, ws.pointNumbers, true);
    if (parsed.hasError)
        return fontErr!bool(parsed.error);
    const count = parsed.value.count;
    if (ws.deltaX.length < count || ws.deltaY.length < count || ws.referenced.length < count)
        return fontErr!bool(callerStorageError(count, gvarTag, start));
    const indices = ws.pointNumbers[0 .. count];
    int[] dx = ws.deltaX, dy = ws.deltaY;
    const x = readSparseDeltas(d, info.pointDataAt, dx[0 .. count], start, limit);
    if (x.hasError)
        return fontErr!bool(x.error);
    const y = readSparseDeltas(d, x.value, dy[0 .. count], start, limit);
    if (y.hasError)
        return fontErr!bool(y.error);
    auto original = simplePointReader(face, gid);
    if (original.hasError)
        return fontErr!bool(original.error);
    // Composite pseudo-points have no contours and must not infer deltas.
    if (original.value.ends.length == 0)
    {
        foreach (i, index; indices)
        {
            const delta = OutlinePoint(long(dx[i]) * info.scalar / (tupleScalarOne / 65_536),
                long(dy[i]) * info.scalar / (tupleScalarOne / 65_536));
            if (index < points.length)
            {
                points[index].x += delta.x;
                points[index].y += delta.y;
            }
            else
            {
                phantom[index - points.length].x += delta.x;
                phantom[index - points.length].y += delta.y;
            }
        }
        return fontOk(true);
    }
    // The stored coordinates of the referenced points, in font units: glyf
    // coordinates are 16-bit, so ints hold them in half an OutlinePoint.
    int[2][] referenced = ws.referenced;
    auto reader = original.value;
    size_t refIndex;
    foreach (p; 0 .. points.length)
    {
        const point = reader.next();
        if (refIndex < count && indices[refIndex] == p)
            referenced[refIndex++] = [cast(int)(point.x >> 16), cast(int)(point.y >> 16)];
    }
    long refX(size_t i) => long(referenced[i][0]) << 16;
    long refY(size_t i) => long(referenced[i][1]) << 16;
    reader = original.value;
    size_t contourStart, firstRef;
    foreach (c; 0 .. reader.ends.length / 2)
    {
        const contourEnd = size_t(be16(reader.ends, 2 * c)) + 1;
        size_t endRef = firstRef;
        while (endRef < count && indices[endRef] < contourEnd)
            ++endRef;
        size_t nextRef = firstRef;
        foreach (p; contourStart .. contourEnd)
        {
            const point = reader.next();
            if (firstRef == endRef)
                continue;
            while (nextRef < endRef && indices[nextRef] < p)
                ++nextRef;
            long deltaX, deltaY;
            if (nextRef < endRef && indices[nextRef] == p)
            {
                deltaX = long(dx[nextRef]) << 16;
                deltaY = long(dy[nextRef]) << 16;
            }
            else
            {
                const before = nextRef == firstRef ? endRef - 1 : nextRef - 1;
                const after = nextRef == endRef ? firstRef : nextRef;
                deltaX = inferredDelta(point.x, refX(before), refX(after), dx[before], dx[after]);
                deltaY = inferredDelta(point.y, refY(before), refY(after), dy[before], dy[after]);
            }
            points[p].x += deltaX * info.scalar / tupleScalarOne;
            points[p].y += deltaY * info.scalar / tupleScalarOne;
        }
        contourStart = contourEnd;
        firstRef = endRef;
    }
    foreach (i; firstRef .. count)
    {
        const index = indices[i] - points.length;
        phantom[index].x += long(dx[i]) * info.scalar / (tupleScalarOne / 65_536);
        phantom[index].y += long(dy[i]) * info.scalar / (tupleScalarOne / 65_536);
    }
    return fontOk(true);
}

private struct PointList
{
    bool all;
    size_t consumed;
    const(ubyte)[] data; // the packed run bytes after the count preamble
    size_t countPos; // unused
    size_t total;
    bool parseOk;
}

private FontResult!PointList parsePointNumbers(const(ubyte)[] d, size_t at, size_t totalPoints,
    ulong tableStart, ulong limit)
{
    // Returns the decoded point indices via `decodePointList`.
    if (at >= d.length)
        return fontErr!PointList(tableError(FontErrorKind.truncated, gvarTag, tableStart, at));
    const first = d[at];
    if (first == 0)
        return fontOk(PointList(true, 1, d[at .. at + 1], 0, totalPoints, true));
    // Count and runs follow; validate by decoding.
    const decoded = decodePointList(d, at, totalPoints, tableStart, limit, null, false);
    if (decoded.hasError)
        return fontErr!PointList(decoded.error);
    return fontOk(PointList(false, decoded.value.consumed,
        d[at .. at + decoded.value.consumed], 0, totalPoints, true));
}

private struct DecodedPoints
{
    size_t consumed;
    size_t count;
    bool all;
}

/**
Decodes a packed point-number list at `at`, writing the numbers to
`indices` when `store` is set (a short array is `callerStorage`) and only
validating and counting them otherwise.
*/
private FontResult!DecodedPoints decodePointList(scope const(ubyte)[] d, size_t at,
    size_t totalPoints, ulong tableStart, ulong limit, scope uint[] indices, bool store)
{
    DecodedPoints result;
    if (at >= d.length)
        return fontErr!DecodedPoints(tableError(FontErrorKind.truncated, gvarTag, tableStart, at));
    size_t p = at;
    const first = d[p++];
    if (first == 0)
    {
        result.all = true;
        result.consumed = 1;
        result.count = totalPoints;
        return fontOk(result);
    }
    size_t count;
    if (first & 0x80)
    {
        if (p >= d.length)
            return fontErr!DecodedPoints(tableError(FontErrorKind.truncated, gvarTag, tableStart, p));
        count = (size_t(first & 0x7F) << 8) + d[p++];
    }
    else
        count = first;
    size_t produced;
    size_t current;
    bool firstPoint = true;
    while (produced < count)
    {
        if (p >= d.length)
            return fontErr!DecodedPoints(tableError(FontErrorKind.truncated, gvarTag, tableStart, p));
        const control = d[p++];
        const words = (control & 0x80) != 0;
        const run = (control & 0x7F) + 1;
        foreach (_; 0 .. run)
        {
            size_t delta;
            if (words)
            {
                if (!fits(d.length, p, 2))
                    return fontErr!DecodedPoints(tableError(FontErrorKind.truncated, gvarTag,
                        tableStart, p));
                delta = be16(d, p);
                p += 2;
            }
            else
            {
                if (p >= d.length)
                    return fontErr!DecodedPoints(tableError(FontErrorKind.truncated, gvarTag,
                        tableStart, p));
                delta = d[p++];
            }
            current = firstPoint ? delta : current + delta;
            firstPoint = false;
            if (current >= totalPoints && totalPoints != 0)
                return fontErr!DecodedPoints(tableError(FontErrorKind.badValue, gvarTag,
                    tableStart, at));
            if (store)
            {
                if (result.count >= indices.length)
                    return fontErr!DecodedPoints(callerStorageError(count, gvarTag, tableStart + at, at));
                indices[result.count] = cast(uint) current;
            }
            ++result.count;
            ++produced;
        }
    }
    result.consumed = p - at;
    return fontOk(result);
}

private size_t listCount(in PointList list, size_t totalPoints)
{
    if (list.all)
        return totalPoints;
    const r = decodePointList(list.data, 0, totalPoints, 0, 0, null, false);
    return r.hasValue ? r.value.count : 0;
}


/// Advances past one packed delta series; returns the new offset.
private FontResult!size_t skipDeltaSeries(scope const(ubyte)[] d, size_t at, size_t count,
    ulong tableStart, ulong limit)
{
    const end = limit < d.length ? cast(size_t) limit : d.length;
    size_t p = at;
    size_t produced;
    while (produced < count)
    {
        if (p >= end)
            return fontErr!size_t(tableError(FontErrorKind.truncated, gvarTag, tableStart, p));
        const control = d[p++];
        const run = (control & 0x3F) + 1;
        if (run > count - produced)
            return fontErr!size_t(tableError(FontErrorKind.badValue, gvarTag, tableStart, p - 1));
        p += deltaWidth(control) * run;
        if (p > end)
            return fontErr!size_t(tableError(FontErrorKind.truncated, gvarTag, tableStart, p));
        produced += run;
    }
    return fontOk(p);
}

/// Applies one delta series (x when `isY` is false) to points and phantom.
private FontResult!bool applyDeltaSeries(scope const(ubyte)[] d, size_t at, in PointList list,
    size_t totalPoints, long scalar, scope OutlinePoint[] points, scope OutlinePoint[] phantom,
    ulong tableStart, scope uint[] scratch, bool isY = false)
{
    // Decode the point indices.
    const allPoints = list.all;
    const decoded = allPoints ? fontOk(DecodedPoints.init)
        : decodePointList(list.data, 0, totalPoints, tableStart, 0, scratch, true);
    if (decoded.hasError)
        return fontErr!bool(decoded.error);
    scope const(uint)[] indices = scratch[0 .. decoded.value.count];
    const count = allPoints ? totalPoints : indices.length;
    size_t p = at;
    size_t produced;
    size_t ordinal;
    while (produced < count)
    {
        if (p >= d.length)
            return fontErr!bool(tableError(FontErrorKind.truncated, gvarTag, tableStart, p));
        const control = d[p++];
        const run = (control & 0x3F) + 1;
        const width = deltaWidth(control);
        foreach (_; 0 .. run)
        {
            if (!fits(d.length, p, width))
                return fontErr!bool(tableError(FontErrorKind.truncated, gvarTag, tableStart, p));
            const long delta = packedDelta(d, p, width);
            p += width;
            if (ordinal < count && delta != 0)
            {
                const pointIndex = allPoints ? ordinal : indices[ordinal];
                // Convert the scaled font-unit delta to 16.16 coordinates.
                const scaled = delta * scalar / (tupleScalarOne / 65_536);
                if (pointIndex < points.length)
                {
                    if (isY) points[pointIndex].y += scaled;
                    else points[pointIndex].x += scaled;
                }
                else if (pointIndex - points.length < phantom.length)
                {
                    const pi = pointIndex - points.length;
                    if (isY) phantom[pi].y += scaled;
                    else phantom[pi].x += scaled;
                }
            }
            ++ordinal;
            ++produced;
        }
    }
    return fontOk(true);
}

// ---------------------------------------------------------------------------
// glyf entry points
// ---------------------------------------------------------------------------

/**
Fills `result`'s phantom points for glyph `gid` (FTO5) and translates
the decoded points so the left phantom point sits at the glyph origin,
as `hb_font_draw_glyph` and FreeType present an outline: the stored
points are shifted in x by `lsb − xMin` (the phantom point's varied
position at the instance). A glyph with no `glyf` entry still has
phantom points. CFF glyphs have none.
*/
private void attachPhantom(in OutlinePoint[4] phantom, scope OutlineWorkspace ws,
    size_t pointCount, ref GlyphOutline result)
{
    result.phantom = phantom;
    result.hasPhantom = true;
    if (phantom[0].x != 0)
        foreach (ref point; ws.points[0 .. pointCount])
            point.x -= phantom[0].x;
}
private FontResult!GlyphOutline expandGlyf(in Instance inst, uint gid,
    ref SegmentWriter writer, return scope OutlineWorkspace ws)
{
    const face = inst.face;
    auto tables = glyfTables(face);
    if (tables.hasError)
        return fontErr!GlyphOutline(tables.error);
    if (!tables.value.present)
        return fontErr!GlyphOutline(FontError(FontErrorKind.missingTable, glyfTag));
    Expander e;
    e.face = face;
    e.inst = inst;
    e.tables = tables.value;
    e.ws = ws;
    const expanded = expandGlyph(e, gid, Transform.init, 0, null);
    if (expanded.hasError)
        return fontErr!GlyphOutline(expanded.error);

    GlyphOutline result;
    result.pointCount = e.pointCount;
    result.contourCount = e.contourCount;
    result.overlap = e.overlap;
    result.empty = e.pointCount == 0;

    attachPhantom(e.phantom, ws, e.pointCount, result);
    emitSegments(ws, e.pointCount, e.contourCount, writer);
    result.segmentCount = writer.count;
    return fontOk(result);
}

/// Emits segments for the expanded points in `ws`.
private void emitSegments(in OutlineWorkspace ws, size_t pointCount, size_t contourCount,
    ref SegmentWriter writer)
{
    size_t contourStart;
    foreach (c; 0 .. contourCount)
    {
        const contourEnd = ws.contourEnds[c];
        emitContour(ws.points[contourStart .. contourEnd + 1],
            ws.onCurve[contourStart .. contourEnd + 1], writer);
        contourStart = contourEnd + 1;
    }
}

/// How many contours ending at `ends` draw anything: those of two points or more.
private size_t drawnContours(scope const(ushort)[] ends)
{
    size_t drawn, start;
    foreach (end; ends)
    {
        if (end > start)
            ++drawn;
        start = end + 1;
    }
    return drawn;
}

/// The implied on-curve point between two off-curve points.
private OutlinePoint midpoint(OutlinePoint a, OutlinePoint b)
    => OutlinePoint((a.x + b.x) / 2, (a.y + b.y) / 2);

// ---------------------------------------------------------------------------
// Public glyf/CFF dispatch
// ---------------------------------------------------------------------------

/**
The outline of glyph `gid` of `inst` as segments in `segments` (FTO2):
returns the segment count and what was found. When `segments` is too
small the result is a `limitExceeded` error naming `callerStorage` with
the exact count in `needed`, after a counting pass that writes nothing
past the array. `ws` holds the decoded points of a `glyf` glyph.

Costs O(p · t) for a `glyf` glyph of `p` points under `t` `gvar` tuples, O(p)
at the default instance, and O(n) for a charstring of `n` operations (at
most 65,536, FTB3). A sparse `gvar` tuple holds its point list and deltas
in about 100 KiB of stack, so it may name at most 4,096 points; more is
`limitExceeded` naming `callerStorage`.
*/
FontResult!GlyphOutline glyphOutline(in Instance inst, uint gid, scope OutlineSegment[] segments,
    return scope OutlineWorkspace ws)
{
    SegmentWriter writer;
    writer.buffer = segments;
    auto result = inst.face.outlines == OutlineFormat.cff
        ? cffOutline(inst, gid, writer) : expandGlyf(inst, gid, writer, ws);
    if (result.hasValue && writer.count > segments.length)
        return fontErr!GlyphOutline(callerStorageError(writer.count));
    return result;
}

/**
The decoded point `pointIndex` of glyph `gid` at `inst` (the outline-point
primitive of FTM7/FTS10): points are counted in glyph order, on- and
off-curve, phantom points excluded. The points are decoded into `ws`.
Costs as `glyphOutline`.
*/
FontResult!OutlinePoint glyphPoint(in Instance inst, uint gid, size_t pointIndex,
    return scope ref PointWorkspace ws)
{
    SegmentWriter writer; // counting only: no buffer
    const result = inst.face.outlines == OutlineFormat.cff
        ? cffOutline(inst, gid, writer) : expandGlyf(inst, gid, writer, ws.outline);
    if (result.hasError)
        return fontErr!OutlinePoint(result.error);
    if (inst.face.outlines == OutlineFormat.cff)
        return fontErr!OutlinePoint(FontError(FontErrorKind.unsupportedCapability, cffTag));
    if (pointIndex >= result.value.pointCount)
        return fontErr!OutlinePoint(FontError(FontErrorKind.indexOutOfRange, glyfTag));
    return fontOk(ws.points[pointIndex]);
}

/**
The horizontal advance of glyph `gid` at `inst` from its phantom points
(FTO5): the span between phantom points 0 and 1 after `gvar`. This is
the advance a face without `HVAR` uses. Costs as `glyphPoint`.
*/
FontResult!DesignValue phantomAdvance(in Instance inst, uint gid, scope ref PointWorkspace ws)
{
    const phantom = variedPhantom(inst, gid, ws);
    if (phantom.hasError)
        return fontErr!DesignValue(phantom.error);
    return fontOk(DesignValue(phantom.value[1].x - phantom.value[0].x, inst.unitsPerEm));
}

private FontResult!(OutlinePoint[4]) variedPhantom(in Instance inst, uint gid,
    scope ref PointWorkspace ws)
{
    SegmentWriter writer;
    const result = expandGlyf(inst, gid, writer, ws.outline);
    if (result.hasError)
        return fontErr!(OutlinePoint[4])(result.error);
    if (!result.value.hasPhantom)
        return fontErr!(OutlinePoint[4])(FontError(FontErrorKind.unsupportedCapability, glyfTag));
    return fontOk!(OutlinePoint[4])(result.value.phantom);
}

/**
The point bounds of glyph `gid` at `inst`: the smallest axis-aligned box
holding every decoded point, or an empty result for a glyph without
points. Control points count, so this is the control box. Costs as
`glyphPoint`.
*/
FontResult!GlyphBounds glyphBounds(in Instance inst, uint gid, scope ref PointWorkspace storage)
{
    auto ws = storage.outline;
    if (inst.face.outlines == OutlineFormat.cff)
    {
        // Bounds from segments: use a bounds writer over the interpreter.
        auto bw = BoundsWriter();
        const r = cffOutlineSink(inst, gid, bw);
        if (r.hasError)
            return fontErr!GlyphBounds(r.error);
        return fontOk(bw.bounds);
    }
    // Points only: no phantom points, so no hmtx is needed.
    const face = inst.face;
    auto tables = glyfTables(face);
    if (tables.hasError)
        return fontErr!GlyphBounds(tables.error);
    if (!tables.value.present)
        return fontErr!GlyphBounds(FontError(FontErrorKind.missingTable, glyfTag));
    Expander e;
    e.face = face;
    e.inst = inst;
    e.requireMetrics = false;
    e.tables = tables.value;
    e.ws = ws;
    const expanded = expandGlyph(e, gid, Transform.init, 0, null);
    if (expanded.hasError)
        return fontErr!GlyphBounds(expanded.error);
    const shiftX = -e.phantom[0].x;
    if (shiftX != 0)
        foreach (ref point; ws.points[0 .. e.pointCount])
            point.x += shiftX;
    GlyphBounds b;
    if (e.pointCount == 0)
        return fontOk(b);
    b.present = true;
    b.xMin = b.xMax = ws.points[0].x;
    b.yMin = b.yMax = ws.points[0].y;
    foreach (p; ws.points[1 .. e.pointCount])
    {
        if (p.x < b.xMin) b.xMin = p.x;
        if (p.x > b.xMax) b.xMax = p.x;
        if (p.y < b.yMin) b.yMin = p.y;
        if (p.y > b.yMax) b.yMax = p.y;
    }
    return fontOk(b);
}

/// A glyph's control-point bounds in 1/65,536 font units; `present` false when empty.
struct GlyphBounds
{
    @safe pure nothrow @nogc:

    bool present;
    long xMin, yMin, xMax, yMax;
}

private struct BoundsWriter
{
    @safe pure nothrow @nogc:

    GlyphBounds bounds;

    void moveTo(OutlinePoint p) => add(p);
    void lineTo(OutlinePoint p) => add(p);
    void quadTo(OutlinePoint c, OutlinePoint p) { add(c); add(p); }
    void cubicTo(OutlinePoint c1, OutlinePoint c2, OutlinePoint p) { add(c1); add(c2); add(p); }
    void close() {}

    private void add(OutlinePoint p)
    {
        if (!bounds.present)
        {
            bounds = GlyphBounds(true, p.x, p.y, p.x, p.y);
            return;
        }
        if (p.x < bounds.xMin) bounds.xMin = p.x;
        if (p.x > bounds.xMax) bounds.xMax = p.x;
        if (p.y < bounds.yMin) bounds.yMin = p.y;
        if (p.y > bounds.yMax) bounds.yMax = p.y;
    }
}

/**
Whether glyph `gid`'s outline data flags overlapping contours (FTI6):
false for a face without `glyf`, for an empty glyph, and on `missingTable`
when `glyf` is absent. Costs O(p) for a glyph of `p` points or components.
*/
FontResult!bool glyphOverlaps(return scope const Face face, uint gid)
{
    auto tables = glyfTables(face);
    if (tables.hasError)
        return fontErr!bool(tables.error);
    if (!tables.value.present)
        return fontOk(false);
    if (gid >= face.numGlyphs)
        return fontErr!bool(FontError(FontErrorKind.indexOutOfRange, glyfTag));
    const t = tables.value;
    const range = glyphRange(t, gid, face.numGlyphs);
    if (range.hasError)
        return fontErr!bool(range.error);
    if (range.value.empty)
        return fontOk(false);
    const d = t.glyf;
    const r = range.value;
    if (r.contours >= 0)
    {
        // Walk the flag stream for OVERLAP_SIMPLE (0x40).
        size_t at = r.begin + 10 + 2 * cast(size_t) r.contours;
        if (!fits(d.length, at, 2))
            return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag, t.glyfStart, at));
        at += 2 + be16(d, at);
        const total = r.contours == 0 ? 0
            : cast(size_t) be16(d, r.begin + 10 + 2 * (cast(size_t) r.contours - 1)) + 1;
        size_t produced;
        while (produced < total)
        {
            if (at >= r.end)
                return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag, t.glyfStart, at));
            const flag = d[at++];
            if (flag & 0x40)
                return fontOk(true);
            size_t n = 1;
            if (flag & 0x08)
            {
                if (at >= r.end)
                    return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag,
                        t.glyfStart, at));
                n += d[at++];
            }
            produced += n;
        }
        return fontOk(false);
    }
    // Composite: any component flag with OVERLAP_COMPOUND (0x0400).
    size_t at = r.begin + 10;
    bool more = true;
    while (more)
    {
        if (!fits(d.length, at, 4) || at + 4 > r.end)
            return fontErr!bool(tableError(FontErrorKind.truncated, glyfTag, t.glyfStart, at));
        const flags = be16(d, at);
        if (flags & 0x0400)
            return fontOk(true);
        at += 4 + ((flags & 0x0001) ? 4 : 2);
        if (flags & 0x0008) at += 2;
        else if (flags & 0x0040) at += 4;
        else if (flags & 0x0080) at += 8;
        more = (flags & 0x0020) != 0;
    }
    return fontOk(false);
}
