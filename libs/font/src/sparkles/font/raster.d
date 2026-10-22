/**
Grayscale rasterization (`docs/specs/font/SPEC.md` § 11, FTA5,
FTR1–FTR4, FTR6, FTR8).

`rasterizeGlyph` renders one glyph of an instance at a pixel size into
a caller-owned coverage region with its own row stride, by signed-area
accumulation (the font-rs algorithm): every flattened edge deposits
signed area per pixel row, and one prefix sum per row yields exact
nonzero-winding coverage (FTR2). Coverage is linear (FTR4); display
gamma is the consumer's separate transfer (`applyTransfer`).

Curves flatten two ways (FTX10): the default policy subdivides to a
0.02 px tolerance, and `FlattenPolicy.freeType` reproduces the
subdivision rules of FreeType's `ftgrays.c`, which is the policy the
FreeType differential (FTR3) is measured under. Overlapping contours
render as an approximation of their union — always when the caller
asks, and for `glyf` glyphs flagged `OVERLAP_SIMPLE`/`OVERLAP_COMPOUND`
— by rendering at 4×4 supersampling and averaging (FTX9): each
subpixel follows the nonzero rule, so only the edge subpixels of
overlapping contours still double. Any other glyph accumulates
directly, as FreeType does.

Nothing allocates (FTB4): points, segments, the accumulation buffer
and the supersampling strip are the caller's `RasterWorkspace`, sized
from `rasterMeasure`. Equal glyph keys produce byte-identical output
(FTR6): the same key drives the same segments through the same
arithmetic.

A glyph box must lie within `maxRasterCoordinate` pixels of the pen
on both axes; a larger ppem or a larger outline is `arithmeticExhausted`,
never a wrapped size.
*/
module sparkles.font.raster;

import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontResult,
    fontErr, fontOk, Tag;
import sparkles.font.face : Face, OutlineFormat;
import sparkles.font.instance : Instance;
import sparkles.font.outlines : glyphOutline, GlyphOutline, OutlinePoint, OutlineSegment,
    OutlineWorkspace, SegmentKind;
import sparkles.font.units : DesignValue, Ppem, toPixels;

import core.checkedint : addu, mulu;

@safe pure nothrow @nogc:

/**
How far, in pixels, a glyph box may reach from the pen on either axis:
2^27, so that the box at 4×4 supersampling, plus its two guard
columns, still fits an `int`.
*/
enum int maxRasterCoordinate = 1 << 27;

/// Which curve-subdivision rules flattening follows (FTR3, FTR8).
enum FlattenPolicy : ubyte
{
    /// Subdivide to 0.02 px.
    standard,
    /// Reproduce FreeType's `ftgrays.c` subdivision rules.
    freeType,
    /// Subdivide to 0.001 px: the converged reference of FTR8.
    fine,
}

/// Whether overlapping contours render as their union (FTR2).
enum OverlapMode : ubyte
{
    /// Union only for glyphs whose outline data flags overlap.
    perGlyphFlag,
    /// Union for every glyph (4×4 supersampling).
    forceUnion,
    /// Always accumulate, doubling coverage where contours overlap.
    accumulate,
}

/// Caller-owned rasterization storage (FTA4, FTA5).
struct RasterWorkspace
{
    @safe pure nothrow @nogc:

    /// Outline segments of one glyph.
    OutlineSegment[] segments;
    /// Outline points of one `glyf` glyph.
    OutlinePoint[] points;
    /// Whether `points[i]` lies on the curve.
    bool[] onCurve;
    /// The last point index of each contour.
    ushort[] contourEnds;
    /// Signed-area accumulation: `accumulationNeeded` floats.
    float[] accumulation;
    /// Supersampling strip for union rendering: `supersampleNeeded` bytes (four subpixel rows).
    ubyte[] supersample;

    /// The workspace as the outline decoder's workspace.
    OutlineWorkspace outline() return scope
    {
        OutlineWorkspace ws;
        ws.points = points;
        ws.onCurve = onCurve;
        ws.contourEnds = contourEnds;
        return ws;
    }
}

/// A caller-owned coverage region: `height` rows of `stride` bytes.
struct RasterRegion
{
    @safe pure nothrow @nogc:

    ubyte[] data;
    size_t stride;
    int width, height;
}

/// A glyph's rasterized box: its size and where it sits from the pen.
struct RasterGlyph
{
    @safe pure nothrow @nogc:

    /// The coverage size in pixels; zero for an empty glyph.
    int width, height;
    /// Pixels from the pen position to the box's left edge.
    int bearingX;
    /// Pixels from the baseline up to the box's top edge.
    int bearingY;
    /// Whether the glyph has any outline at all.
    bool empty;
    /// Accumulation floats and supersample bytes the workspace needs.
    size_t accumulationNeeded, supersampleNeeded;
    /// Whether union rendering (4×4) applies under `perGlyphFlag`.
    bool overlap;
}

private double pixelScale(in Instance inst, Ppem ppem)
    => toPixels(DesignValue.fromUnits(1, inst.unitsPerEm), ppem);

/**
The size, bearings and workspace needs of glyph `gid` at `ppem`
(FTR1), without drawing. The region is anchored on whole pixels: its
left edge is the floor of the outline's leftmost control point and its
top the ceiling of the highest, in the drawn glyph space.

An invalid `ppem` is `badValue`; a box reaching past
`maxRasterCoordinate`, or storage needs past `size_t`, is
`arithmeticExhausted`. Cost: one `glyphOutline` decode, then one pass
over its segments.
*/
FontResult!RasterGlyph rasterMeasure(in Instance inst, uint gid, Ppem ppem,
    return scope RasterWorkspace ws, OverlapMode overlap = OverlapMode.perGlyphFlag)
{
    if (!ppem.valid)
        return fontErr!RasterGlyph(FontError(FontErrorKind.badValue));
    auto outlineWs = ws.outline;
    const result = glyphOutline(inst, gid, ws.segments, outlineWs);
    if (result.hasError)
        return fontErr!RasterGlyph(result.error);
    return measureSegments(inst, ws.segments[0 .. result.value.segmentCount], result.value.overlap,
        ppem, overlap);
}

/// Whether `overlap` renders a glyph whose flag is `flagged` as the 4×4 union.
private bool rendersUnion(OverlapMode overlap, bool flagged)
    => overlap == OverlapMode.forceUnion || overlap == OverlapMode.perGlyphFlag && flagged;

/// `rasterMeasure` over already decoded segments.
private FontResult!RasterGlyph measureSegments(in Instance inst, scope const(OutlineSegment)[] segments,
    bool flagged, Ppem ppem, OverlapMode overlap)
{
    RasterGlyph size;
    size.empty = segments.length == 0;
    size.overlap = flagged;
    if (size.empty)
        return fontOk(size);
    const scale = pixelScale(inst, ppem);
    double xMin = double.max, yMin = double.max, xMax = -double.max, yMax = -double.max;
    foreach (segment; segments)
    {
        void take(OutlinePoint p)
        {
            const x = p.xUnits * scale, y = p.yUnits * scale;
            if (x < xMin) xMin = x;
            if (x > xMax) xMax = x;
            if (y < yMin) yMin = y;
            if (y > yMax) yMax = y;
        }

        if (segment.kind == SegmentKind.close)
            continue;
        take(segment.end);
        if (segment.kind == SegmentKind.quadTo || segment.kind == SegmentKind.cubicTo)
            take(segment.control1);
        if (segment.kind == SegmentKind.cubicTo)
            take(segment.control2);
    }
    import std.math : ceil, floor;

    // Negated so that a NaN fails too; then every cast below is in range.
    enum double limit = maxRasterCoordinate;
    if (!(xMin >= -limit && xMax <= limit && yMin >= -limit && yMax <= limit))
        return fontErr!RasterGlyph(FontError(FontErrorKind.arithmeticExhausted));
    const left = cast(int) floor(xMin), top = cast(int) ceil(yMax);
    size.width = cast(int) ceil(xMax) - left;
    size.height = top - cast(int) floor(yMin);
    size.bearingX = left;
    size.bearingY = top;
    const ss = rendersUnion(overlap, flagged) ? 4 : 1;
    bool overflow;
    const accumulation = mulu(ulong(ss * size.width + 2), ulong(ss * size.height), overflow);
    const supersample = ss == 4 ? mulu(16, ulong(size.width), overflow) : 0;
    if (overflow || accumulation > size_t.max || supersample > size_t.max)
        return fontErr!RasterGlyph(FontError(FontErrorKind.arithmeticExhausted));
    size.accumulationNeeded = cast(size_t) accumulation;
    size.supersampleNeeded = cast(size_t) supersample;
    return fontOk(size);
}

// ---------------------------------------------------------------------------
// Accumulation (FTR2)
// ---------------------------------------------------------------------------

private struct Accumulator
{
    @safe pure nothrow @nogc:

    float[] acc;
    int w, h; // in (super) pixels
    int stride; // w + 2

    void line(double x0, double y0, double x1, double y1) scope
    {
        import std.math : ceil, floor;

        if (y0 == y1)
            return;
        double dir = 1;
        if (y0 > y1)
        {
            dir = -1;
            const tx = x0; x0 = x1; x1 = tx;
            const ty = y0; y0 = y1; y1 = ty;
        }
        const dxdy = (x1 - x0) / (y1 - y0);
        double x = x0;
        if (y0 < 0)
            x -= y0 * dxdy;
        const yStart = y0 < 0 ? 0 : cast(int) y0;
        const yEnd = y1 > h ? h : cast(int) ceil(y1);
        for (int y = yStart; y < yEnd; ++y)
        {
            const row = y * stride;
            const dy = (y + 1 < y1 ? y + 1.0 : y1) - (y > y0 ? y : y0);
            const xNext = x + dxdy * dy;
            const d = dy * dir;
            const xa = x < xNext ? x : xNext, xb = x < xNext ? xNext : x;
            const xaFloor = floor(xa);
            const xai = cast(int) xaFloor;
            const xbi = cast(int) ceil(xb);
            // Columns outside [0, w + 1] fold into the nearest one in
            // range: a deposit left of the box counts toward every
            // pixel's prefix sum exactly as a deposit at column 0
            // does, and one right of it toward none. Dropping them
            // instead would lose an edge that merely ends a rounding
            // error outside the box, and with it the row's winding.
            void deposit(int column, double amount)
            {
                const c = column < 0 ? 0 : column > w + 1 ? w + 1 : column;
                acc[row + c] += cast(float) amount;
            }

            if (xbi <= xai + 1)
            {
                const xmf = 0.5 * (x + xNext) - xaFloor;
                deposit(xai, d - d * xmf);
                deposit(xai + 1, d * xmf);
            }
            else
            {
                const s = 1.0 / (xb - xa);
                const xaf = xa - xaFloor;
                const a0 = 0.5 * s * (1 - xaf) * (1 - xaf);
                const xbf = xb - xbi + 1;
                const am = 0.5 * s * xbf * xbf;
                deposit(xai, d * a0);
                if (xbi == xai + 2)
                    deposit(xai + 1, d * (1 - a0 - am));
                else
                {
                    const a1 = s * (1.5 - xaf);
                    deposit(xai + 1, d * (a1 - a0));
                    foreach (xi; xai + 2 .. xbi - 1)
                        deposit(xi, d * s);
                    const a2 = a1 + (xbi - xai - 3) * s;
                    deposit(xbi - 1, d * (1 - a2 - am));
                }
                deposit(xbi, d * am);
            }
            x = xNext;
        }
    }
}

/// Flattens one segment from (`x0`, `y0`) into `acc`, returning its end.
private OutlinePoint flatten(scope ref Accumulator acc, OutlinePoint from, OutlineSegment segment,
    double scale, double left, double top, FlattenPolicy policy)
{
    double px(OutlinePoint p) => p.xUnits * scale - left;
    double py(OutlinePoint p) => top - p.yUnits * scale;
    const tolerance = policy == FlattenPolicy.fine ? 0.001 : 0.02;

    void lineTo(OutlinePoint p) => acc.line(px(from), py(from), px(p), py(p));
    final switch (segment.kind)
    {
        case SegmentKind.moveTo:
        case SegmentKind.lineTo:
        case SegmentKind.close:
            if (segment.kind == SegmentKind.lineTo)
                lineTo(segment.end);
            return segment.end;
        case SegmentKind.quadTo:
        {
            const c = segment.control1, e = segment.end;
            if (policy == FlattenPolicy.freeType)
            {
                // ftgrays.c: bisect (as a step count) until the deviation
                // quartered per doubling is within a quarter pixel.
                double dev = absd(px(from) + px(e) - 2 * px(c));
                const devY = absd(py(from) + py(e) - 2 * py(c));
                if (devY > dev) dev = devY;
                int n = 1;
                if (dev > 0.25)
                    do { dev /= 4; n *= 2; } while (dev > 0.25);
                const p0 = from;
                foreach (i; 1 .. n + 1)
                {
                    const t = cast(double) i / n, u = 1 - t;
                    const p = OutlinePoint(
                        cast(long)((u * u * p0.x + 2 * u * t * c.x + t * t * e.x)),
                        cast(long)((u * u * p0.y + 2 * u * t * c.y + t * t * e.y)));
                    lineTo(p);
                    from = p;
                }
            }
            else
            {
                import std.math : ceil, hypot, sqrt;

                const sd = hypot(px(from) - 2 * px(c) + px(e), py(from) - 2 * py(c) + py(e));
                const n = sd <= 0 ? 1 : cast(int) ceil(sqrt(sd / (4 * tolerance)));
                const p0 = from;
                foreach (i; 1 .. (n < 1 ? 1 : n) + 1)
                {
                    const t = cast(double) i / (n < 1 ? 1 : n), u = 1 - t;
                    const p = OutlinePoint(
                        cast(long)((u * u * p0.x + 2 * u * t * c.x + t * t * e.x)),
                        cast(long)((u * u * p0.y + 2 * u * t * c.y + t * t * e.y)));
                    lineTo(p);
                    from = p;
                }
            }
            return e;
        }
        case SegmentKind.cubicTo:
        {
            const c1 = segment.control1, c2 = segment.control2, e = segment.end;
            if (policy == FlattenPolicy.freeType)
                splitCubic(acc, from, c1, c2, e, scale, left, top, 0);
            else
            {
                import std.math : ceil, hypot, sqrt;

                const sd1 = hypot(px(from) - 2 * px(c1) + px(c2),
                    py(from) - 2 * py(c1) + py(c2));
                const sd2 = hypot(px(c1) - 2 * px(c2) + px(e), py(c1) - 2 * py(c2) + py(e));
                const sd = sd1 > sd2 ? sd1 : sd2;
                const n = sd <= 0 ? 1 : cast(int) ceil(sqrt(sd * 0.75 / tolerance));
                const nn = n < 1 ? 1 : n;
                const p0 = from;
                foreach (i; 1 .. nn + 1)
                {
                    const t = cast(double) i / nn, u = 1 - t;
                    const p = OutlinePoint(
                        cast(long)(u * u * u * p0.x + 3 * u * u * t * c1.x
                            + 3 * u * t * t * c2.x + t * t * t * e.x),
                        cast(long)(u * u * u * p0.y + 3 * u * u * t * c1.y
                            + 3 * u * t * t * c2.y + t * t * t * e.y));
                    lineTo(p);
                    from = p;
                }
            }
            return e;
        }
    }
}

private double absd(double v) => v < 0 ? -v : v;

/// FreeType's cubic bisection (ftgrays.c), depth-bounded at 16.
private void splitCubic(scope ref Accumulator acc, OutlinePoint p0, OutlinePoint p1,
    OutlinePoint p2, OutlinePoint p3, double scale, double left, double top, int depth)
{
    double px(OutlinePoint p) => p.xUnits * scale - left;
    double py(OutlinePoint p) => top - p.yUnits * scale;

    enum limit = 0.5; // pixels
    const far = absd(2 * px(p0) - 3 * px(p1) + px(p3)) > limit
        || absd(2 * py(p0) - 3 * py(p1) + py(p3)) > limit
        || absd(px(p0) - 3 * px(p2) + 2 * px(p3)) > limit
        || absd(py(p0) - 3 * py(p2) + 2 * py(p3)) > limit;
    if (depth >= 16 || !far)
    {
        acc.line(px(p0), py(p0), px(p3), py(p3));
        return;
    }
    OutlinePoint mid(OutlinePoint a, OutlinePoint b)
        => OutlinePoint((a.x + b.x) / 2, (a.y + b.y) / 2);
    const a = mid(p0, p1), b = mid(p1, p2), c = mid(p2, p3);
    const d = mid(a, b), e = mid(b, c), f = mid(d, e);
    splitCubic(acc, p0, a, d, f, scale, left, top, depth + 1);
    splitCubic(acc, f, e, c, p3, scale, left, top, depth + 1);
}

// ---------------------------------------------------------------------------
// Rasterize (FTR1)
// ---------------------------------------------------------------------------

/**
Rasterizes glyph `gid` of `inst` at `ppem` into `region` (FTR1),
returning its box and bearings. The region must be at least the size
`rasterMeasure` reports, and the workspace's accumulation and
supersample arrays at least its stated needs; short storage is
`limitExceeded` naming `callerStorage`, whose `needed` is the length the
short array must have. Only the glyph's box inside the region is
written. The errors of `rasterMeasure` apply.

Cost (FTB3): one `glyphOutline` decode; flattening into lines, at most
`ceil(sqrt(d / 4t))` per quadratic and `ceil(sqrt(0.75 d / t))` per
cubic for a curve whose second difference spans `d` pixels at tolerance
`t` (FreeType's rules: at most 2^16 per curve); each line visits the
rows and columns it crosses; then one pass over `accumulationNeeded`
floats to clear them and one to sum them. Every term is bounded by the
box, which the caller's storage bounds.
*/
FontResult!RasterGlyph rasterizeGlyph(in Instance inst, uint gid, Ppem ppem,
    scope RasterRegion region, return scope RasterWorkspace ws,
    FlattenPolicy policy = FlattenPolicy.standard,
    OverlapMode overlap = OverlapMode.perGlyphFlag)
{
    if (!ppem.valid)
        return fontErr!RasterGlyph(FontError(FontErrorKind.badValue));
    auto outlineWs = ws.outline;
    const drawn = glyphOutline(inst, gid, ws.segments, outlineWs);
    if (drawn.hasError)
        return fontErr!RasterGlyph(drawn.error);
    const segments = ws.segments[0 .. drawn.value.segmentCount];
    const measured = measureSegments(inst, segments, drawn.value.overlap, ppem, overlap);
    if (measured.hasError)
        return measured;
    RasterGlyph size = measured.value;
    if (size.empty)
        return fontOk(size);
    if (region.width < size.width || region.height < size.height
        || region.stride < cast(size_t) size.width
        || size.height > 0 && region.stride > region.data.length / cast(size_t) size.height)
    {
        // The bytes `height` rows of the wider of stride and width need.
        const rowSpan = region.stride < size.width ? ulong(size.width) : ulong(region.stride);
        bool overflow;
        const rows = size.height > 0 ? ulong(size.height - 1) : 0;
        const needed = addu(mulu(rowSpan, rows, overflow), ulong(size.width), overflow);
        return fontErr!RasterGlyph(callerStorageError(overflow ? ulong.max : needed));
    }
    if (ws.accumulation.length < size.accumulationNeeded)
        return fontErr!RasterGlyph(callerStorageError(size.accumulationNeeded));
    if (ws.supersample.length < size.supersampleNeeded)
        return fontErr!RasterGlyph(callerStorageError(size.supersampleNeeded));

    const union_ = rendersUnion(overlap, size.overlap);
    const ss = union_ ? 4 : 1;
    const scale = pixelScale(inst, ppem) * ss;
    const left = cast(double) size.bearingX * ss;
    const top = cast(double) size.bearingY * ss;
    const w = ss * size.width, h = ss * size.height;

    Accumulator acc;
    acc.acc = ws.accumulation[0 .. size.accumulationNeeded];
    acc.acc[] = 0;
    acc.w = w;
    acc.h = h;
    acc.stride = w + 2;

    OutlinePoint current, start;
    foreach (segment; segments)
    {
        switch (segment.kind)
        {
            case SegmentKind.moveTo:
                current = start = segment.end;
                break;
            case SegmentKind.close:
                if (current.x != start.x || current.y != start.y)
                    acc.line(current.xUnits * scale - left, top - current.yUnits * scale,
                        start.xUnits * scale - left, top - start.yUnits * scale);
                current = start;
                break;
            default:
                current = flatten(acc, current, segment, scale, left, top, policy);
                break;
        }
    }

    // Prefix sums: coverage per (super)pixel, then into the region.
    foreach (y; 0 .. size.height)
    {
        auto outRow = region.data[y * region.stride .. y * region.stride + size.width];
        if (!union_)
        {
            double sum = 0;
            foreach (x; 0 .. size.width)
            {
                sum += acc.acc[y * acc.stride + x];
                outRow[x] = coverageByte(sum);
            }
        }
        else
        {
            // Average the 4x4 subpixels of each output pixel.
            foreach (sy; 0 .. 4)
            {
                const rowBase = (4 * y + sy) * acc.stride;
                double sum = 0;
                foreach (x; 0 .. w)
                {
                    sum += acc.acc[rowBase + x];
                    ws.supersample[sy * w + x] = coverageByte(sum);
                }
            }
            foreach (x; 0 .. size.width)
            {
                uint total;
                foreach (sy; 0 .. 4)
                    foreach (sx; 0 .. 4)
                        total += ws.supersample[sy * w + 4 * x + sx];
                outRow[x] = cast(ubyte)((total + 8) / 16);
            }
        }
    }
    return fontOk(size);
}

private ubyte coverageByte(double sum) @safe pure nothrow @nogc
{
    const v = sum < 0 ? -sum : sum;
    const clamped = v > 1 ? 1.0 : v;
    return cast(ubyte)(clamped * 255 + 0.5);
}

/**
The display transfer of FTR4: encodes linear `coverage` for a display
of gamma `gammaTimes256 / 256`, raising it to the power
`256 / gammaTimes256`. 256 is the identity; a larger gamma (563 for
2.2) brightens midtones, a smaller one darkens them. Coverage the
rasterizer produces is linear; this is the consumer's display choice,
applied separately. `gammaTimes256` must be positive.
*/
ubyte applyTransfer(ubyte coverage, uint gammaTimes256) @safe pure nothrow @nogc
in (gammaTimes256 > 0, "applyTransfer: gamma must be positive")
{
    import std.math : pow;

    if (gammaTimes256 == 256)
        return coverage;
    const v = pow(cast(double) coverage / 255, 256.0 / gammaTimes256) * 255;
    return cast(ubyte)(v + 0.5);
}
