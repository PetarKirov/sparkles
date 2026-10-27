/**
Bitmap colour strikes: `CBDT`/`CBLC` and `sbix` (`docs/specs/font/SPEC.md`
FTR7, FTX4).

`bitmapGlyph` finds a glyph's PNG in the strike FTR7 chooses: the
smallest whose ppem is at least the requested size, else the largest,
the rule HarfBuzz follows too. A face with both tables reads `CBDT`. A
`CBLC` strike's size is the larger of its two ppems; an `sbix` strike's
is its ppem.

`rasterizeBitmapGlyph` decodes that PNG (`sparkles.font.png`) and scales
it to the requested size into a premultiplied RGBA region. The glyph's
box scales with the strike, from its bearings in strike pixels; each
output pixel is the area-weighted mean of the image pixels it covers,
transparent where it covers none. At the strike's own size with whole
bearings that is an exact copy.

`CBLC` index subtables of formats 1 to 5 are read, and `CBDT` image
formats 17, 18 and 19 (PNG with small, big or shared metrics); other image
formats are `unsupportedVersion`. `sbix` glyphs of graphic type `png ` are
read, and `dupe` records followed once; other types are
`unsupportedVersion`. Nothing allocates.
*/
module sparkles.font.bitmap;

import sparkles.font.bytes : be16, be32, bes16, fits;
import sparkles.font.colour_raster : ColourGlyph, ColourRegion, ColourSource, ColourWorkspace, regionHolds;
import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontResult, fontErr, fontOk,
    Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.png : decodePng, pngHeader, PngImage, pngZlibScratch;
import sparkles.font.tables : locate, Located;
import sparkles.font.units : Ppem;

@safe pure nothrow @nogc:

/**
A glyph's bitmap in its chosen strike: where its PNG lies and its box in
strike pixels. `source` is `none` when the chosen strike has no bitmap
for the glyph, or the face no strikes.
*/
struct BitmapGlyph
{
    /// `cbdt`, `sbix`, or `none`.
    ColourSource source;
    /// The chosen strike's ppem.
    uint strikePpem;
    /// The PNG, borrowed from the face's bytes.
    const(ubyte)[] png;
    /// The table holding the PNG, and where in the face's bytes that table and the PNG start.
    Tag table;
    /// ditto
    ulong tableStart, pngOffset;
    /// Strike pixels from the pen to the bitmap's left edge, and from the baseline up to its top.
    int bearingX, bearingY;
    /// The bitmap's size in strike pixels.
    uint width, height;
}

private enum cbdtTag = Tag("CBDT"), cblcTag = Tag("CBLC"), sbixTag = Tag("sbix");
private enum uint pngType = 0x706E6720, dupeType = 0x64757065; // 'png ', 'dupe'

/// Whether `ppem` is at most `strike` pixels.
private bool atMost(Ppem ppem, uint strike) => ppem.numerator <= ulong(strike) * ppem.denominator;

/// Whether `candidate` is a better strike than `best` for `ppem` (FTR7).
private bool better(Ppem ppem, uint candidate, uint best)
    => atMost(ppem, candidate) && candidate < best || !atMost(ppem, best) && candidate > best;

/**
The bitmap of glyph `gid` for a request of `ppem` (FTR7), or `source`
`none`. A table whose header or records run past it is `truncated` or
`badOffset`; an index subtable's offsets out of order, or a glyph record
too short for its form, is `badValue`; an image format other than 17, 18
or 19, or an `sbix` graphic type other than `png ` or `dupe`, is
`unsupportedVersion`; a `dupe` naming another `dupe` is `cycle`. Cost:
O(strikes + index subtables of the chosen strike), and a binary search
within index formats 4 and 5.
*/
FontResult!BitmapGlyph bitmapGlyph(return scope const Face face, uint gid, Ppem ppem)
{
    if (!ppem.valid)
        return fontErr!BitmapGlyph(FontError(FontErrorKind.badValue));
    if (face.has(cbdtTag))
        return cbdtGlyph(face, gid, ppem);
    if (face.has(sbixTag))
        return sbixGlyph(face, gid, ppem);
    return fontOk(BitmapGlyph.init);
}

private FontResult!BitmapGlyph cbdtGlyph(return scope const Face face, uint gid, Ppem ppem)
{
    if (!face.has(cblcTag))
        return fontErr!BitmapGlyph(FontError(FontErrorKind.missingTable, cblcTag));
    const lt = locate(face, cblcTag);
    if (lt.hasError)
        return fontErr!BitmapGlyph(lt.error);
    const dt = locate(face, cbdtTag);
    if (dt.hasError)
        return fontErr!BitmapGlyph(dt.error);
    const l = lt.value.data, d = dt.value.data;
    FontError inLoc(FontErrorKind kind, ulong at) => tableError(kind, cblcTag, lt.value.start, at);
    FontError inData(FontErrorKind kind, ulong at) => tableError(kind, cbdtTag, dt.value.start, at);
    if (l.length < 8)
        return fontErr!BitmapGlyph(inLoc(FontErrorKind.truncated, l.length));
    if (be16(l, 0) != 2 && be16(l, 0) != 3)
        return fontErr!BitmapGlyph(inLoc(FontErrorKind.unsupportedVersion, 0));
    const sizes = be32(l, 4);
    if (!fits(l.length, 8, 48UL * sizes))
        return fontErr!BitmapGlyph(inLoc(FontErrorKind.truncated, 8));
    if (sizes == 0)
        return fontOk(BitmapGlyph.init);

    uint strikeSize(size_t i) { const at = 8 + 48 * i; return l[at + 44] > l[at + 45] ? l[at + 44] : l[at + 45]; }
    size_t best;
    foreach (i; 1 .. sizes)
        if (better(ppem, strikeSize(i), strikeSize(best)))
            best = i;
    const size = 8 + 48 * best;
    BitmapGlyph g;
    g.strikePpem = strikeSize(best);
    if (gid < be16(l, size + 40) || gid > be16(l, size + 42))
        return fontOk(g);
    const arrayAt = be32(l, size), subtables = be32(l, size + 8);
    if (!fits(l.length, arrayAt, 8UL * subtables))
        return fontErr!BitmapGlyph(inLoc(arrayAt >= l.length ? FontErrorKind.badOffset : FontErrorKind.truncated, size));
    foreach (i; 0 .. subtables)
    {
        const record = cast(size_t)(arrayAt + 8 * i);
        const first = be16(l, record), last = be16(l, record + 2);
        if (gid < first || gid > last)
            continue;
        const sub = ulong(arrayAt) + be32(l, record + 4);
        if (!fits(l.length, sub, 8))
            return fontErr!BitmapGlyph(inLoc(FontErrorKind.badOffset, record + 4));
        const s = cast(size_t) sub;
        const indexFormat = be16(l, s), imageFormat = be16(l, s + 2), imageAt = be32(l, s + 4);
        // Where the glyph's image lies in CBDT, and big metrics shared by the subtable, if any.
        ulong start, length;
        size_t sharedMetrics; // offset in CBLC of big metrics, 0 for none
        const index = gid - first;
        switch (indexFormat)
        {
            case 1, 3:
            {
                const wide = indexFormat == 1, entry = wide ? 4 : 2;
                if (!fits(l.length, s + 8, ulong(entry) * (last - first + 2)))
                    return fontErr!BitmapGlyph(inLoc(FontErrorKind.truncated, s));
                const at = s + 8 + entry * index;
                const a = wide ? be32(l, at) : be16(l, at), b = wide ? be32(l, at + entry) : be16(l, at + entry);
                if (b < a)
                    return fontErr!BitmapGlyph(inLoc(FontErrorKind.badValue, at));
                start = ulong(imageAt) + a;
                length = b - a;
                break;
            }
            case 2:
                if (!fits(l.length, s + 8, 12))
                    return fontErr!BitmapGlyph(inLoc(FontErrorKind.truncated, s));
                length = be32(l, s + 8);
                start = ulong(imageAt) + length * index;
                sharedMetrics = s + 12;
                break;
            case 4:
            {
                if (!fits(l.length, s + 8, 4))
                    return fontErr!BitmapGlyph(inLoc(FontErrorKind.truncated, s));
                const count = be32(l, s + 8);
                if (!fits(l.length, s + 12, 4UL * (ulong(count) + 1)))
                    return fontErr!BitmapGlyph(inLoc(FontErrorKind.truncated, s));
                const found = search(l, s + 12, count, 4, gid);
                if (found < 0)
                    return fontOk(g);
                const at = s + 12 + 4 * found;
                const a = be16(l, at + 2), b = be16(l, at + 6);
                if (b < a)
                    return fontErr!BitmapGlyph(inLoc(FontErrorKind.badValue, at));
                start = ulong(imageAt) + a;
                length = b - a;
                break;
            }
            case 5:
            {
                if (!fits(l.length, s + 8, 16))
                    return fontErr!BitmapGlyph(inLoc(FontErrorKind.truncated, s));
                const count = be32(l, s + 20);
                if (!fits(l.length, s + 24, 2UL * count))
                    return fontErr!BitmapGlyph(inLoc(FontErrorKind.truncated, s));
                const found = search(l, s + 24, count, 2, gid);
                if (found < 0)
                    return fontOk(g);
                length = be32(l, s + 8);
                start = ulong(imageAt) + length * found;
                sharedMetrics = s + 12;
                break;
            }
            default:
                return fontErr!BitmapGlyph(inLoc(FontErrorKind.unsupportedVersion, s));
        }
        if (length == 0)
            return fontOk(g);
        if (!fits(d.length, start, length))
            return fontErr!BitmapGlyph(inData(start >= d.length ? FontErrorKind.badOffset : FontErrorKind.truncated,
                start));
        const at = cast(size_t) start;
        size_t header; // bytes before the PNG
        int bearingX, bearingY;
        uint width, height;
        void metrics(scope const(ubyte)[] m, size_t i)
        {
            height = m[i];
            width = m[i + 1];
            bearingX = cast(byte) m[i + 2];
            bearingY = cast(byte) m[i + 3];
        }
        switch (imageFormat)
        {
            case 17:
                header = 5 + 4;
                break;
            case 18:
                header = 8 + 4;
                break;
            case 19:
                if (sharedMetrics == 0)
                    return fontErr!BitmapGlyph(inLoc(FontErrorKind.badValue, s + 2));
                header = 4;
                break;
            default:
                return fontErr!BitmapGlyph(inLoc(FontErrorKind.unsupportedVersion, s + 2));
        }
        if (length < header)
            return fontErr!BitmapGlyph(inData(FontErrorKind.badValue, start));
        if (imageFormat == 19)
            metrics(l, sharedMetrics);
        else
            metrics(d, at);
        const pngLength = be32(d, at + header - 4);
        if (pngLength > length - header)
            return fontErr!BitmapGlyph(inData(FontErrorKind.badValue, start + header - 4));
        g.source = ColourSource.cbdt;
        g.table = cbdtTag;
        g.tableStart = dt.value.start;
        g.pngOffset = dt.value.start + start + header;
        g.png = d[at + header .. at + header + pngLength];
        g.bearingX = bearingX;
        g.bearingY = bearingY;
        g.width = width;
        g.height = height;
        return fontOk(g);
    }
    return fontOk(g);
}

/// The index of `gid` among `count` 16-bit glyph ids `stride` bytes apart from `at`, sorted; or -1.
private ptrdiff_t search(scope const(ubyte)[] data, size_t at, size_t count, size_t stride, uint gid)
{
    size_t lo = 0, hi = count;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        const glyph = be16(data, at + stride * mid);
        if (glyph == gid)
            return mid;
        if (glyph < gid)
            lo = mid + 1;
        else
            hi = mid;
    }
    return -1;
}

private FontResult!BitmapGlyph sbixGlyph(return scope const Face face, uint gid, Ppem ppem)
{
    const t = locate(face, sbixTag);
    if (t.hasError)
        return fontErr!BitmapGlyph(t.error);
    const d = t.value.data;
    FontError at(FontErrorKind kind, ulong relative) => tableError(kind, sbixTag, t.value.start, relative);
    if (d.length < 8)
        return fontErr!BitmapGlyph(at(FontErrorKind.truncated, d.length));
    if (be16(d, 0) != 1)
        return fontErr!BitmapGlyph(at(FontErrorKind.unsupportedVersion, 0));
    const strikes = be32(d, 4);
    if (!fits(d.length, 8, 4UL * strikes))
        return fontErr!BitmapGlyph(at(FontErrorKind.truncated, 8));
    if (strikes == 0 || gid >= face.numGlyphs)
        return fontOk(BitmapGlyph.init);
    foreach (i; 0 .. strikes)
        if (!fits(d.length, be32(d, 8 + 4 * i), 4UL * (face.numGlyphs + 2UL)))
            return fontErr!BitmapGlyph(at(FontErrorKind.badOffset, 8 + 4 * i));
    uint strikeSize(size_t i) => be16(d, be32(d, 8 + 4 * i));
    size_t best;
    foreach (i; 1 .. strikes)
        if (better(ppem, strikeSize(i), strikeSize(best)))
            best = i;
    const strike = be32(d, 8 + 4 * best);
    BitmapGlyph g;
    g.strikePpem = strikeSize(best);
    uint glyph = gid;
    foreach (hop; 0 .. 2)
    {
        const offsetAt = strike + 4 + 4 * glyph;
        const a = ulong(strike) + be32(d, offsetAt), b = ulong(strike) + be32(d, offsetAt + 4);
        if (b < a || !fits(d.length, a, b - a))
            return fontErr!BitmapGlyph(at(FontErrorKind.badOffset, offsetAt));
        if (b == a)
            return fontOk(g);
        if (b - a < 8)
            return fontErr!BitmapGlyph(at(FontErrorKind.badValue, a));
        const record = cast(size_t) a;
        const type = be32(d, record + 4);
        if (type == dupeType)
        {
            if (hop == 1)
                return fontErr!BitmapGlyph(at(FontErrorKind.cycle, a));
            if (b - a < 10 || be16(d, record + 8) >= face.numGlyphs)
                return fontErr!BitmapGlyph(at(FontErrorKind.badValue, a));
            glyph = be16(d, record + 8);
            continue;
        }
        if (type != pngType)
            return fontErr!BitmapGlyph(at(FontErrorKind.unsupportedVersion, a + 4));
        g.png = d[record + 8 .. cast(size_t) b];
        const header = pngHeader(g.png);
        if (header.hasError)
            return fontErr!BitmapGlyph(rebase(header.error, sbixTag, t.value.start, a + 8));
        g.source = ColourSource.sbix;
        g.table = sbixTag;
        g.tableStart = t.value.start;
        g.pngOffset = t.value.start + a + 8;
        g.width = header.value.width;
        g.height = header.value.height;
        // The image's lower left corner sits at the origin offset from the pen.
        g.bearingX = bes16(d, record);
        g.bearingY = bes16(d, record + 2) + cast(int) header.value.height;
        return fontOk(g);
    }
    assert(0);
}

/// A PNG error, whose offset is from the PNG's start, as an error in `tag` with the PNG `pngAt` into it.
private FontError rebase(FontError e, Tag tag, ulong tableStart, ulong pngAt)
{
    if (e.kind == FontErrorKind.limitExceeded)
        return e;
    return tableError(e.kind, tag, tableStart, pngAt + e.offset);
}

/// The output box of `g` scaled to `ppem`, from its bearings in strike pixels.
private struct Scaled
{
    int left, top, right, bottom;
    double sx, sy; // output pixels per image pixel
    double originX, originY; // the image's top left corner in output pixels
}

private FontResult!Scaled scaled(in BitmapGlyph g, Ppem ppem, in PngImage image)
{
    import std.math : ceil, floor;

    const s = cast(double) ppem.numerator / (cast(double) ppem.denominator * g.strikePpem);
    Scaled r;
    r.originX = g.bearingX * s;
    r.originY = g.bearingY * s;
    const rightEdge = (g.bearingX + cast(double) g.width) * s, bottomEdge = (g.bearingY - cast(double) g.height) * s;
    enum double limit = 1 << 27;
    if (!(r.originX >= -limit && rightEdge <= limit && bottomEdge >= -limit && r.originY <= limit))
        return fontErr!Scaled(FontError(FontErrorKind.arithmeticExhausted));
    r.left = cast(int) floor(r.originX);
    r.right = cast(int) ceil(rightEdge);
    r.top = cast(int) ceil(r.originY);
    r.bottom = cast(int) floor(bottomEdge);
    // The image fills the metric box, whatever its own size.
    r.sx = s * g.width / image.width;
    r.sy = s * g.height / image.height;
    return fontOk(r);
}

/**
The box of glyph `gid`'s bitmap scaled to `ppem` and the storage drawing
it needs, or `source` `none`. The errors are those of `bitmapGlyph` and
`pngHeader`; a scaled box reaching past `maxRasterCoordinate` is
`arithmeticExhausted`. O(1) past `bitmapGlyph`.
*/
FontResult!ColourGlyph bitmapMeasure(scope const Face face, uint gid, Ppem ppem)
{
    const found = bitmapGlyph(face, gid, ppem);
    if (found.hasError)
        return fontErr!ColourGlyph(found.error);
    const g = found.value;
    ColourGlyph glyph;
    if (g.source == ColourSource.none)
        return fontOk(glyph);
    const header = pngHeader(g.png);
    if (header.hasError)
        return fontErr!ColourGlyph(rebase(header.error, g.table, g.tableStart, g.pngOffset - g.tableStart));
    const image = header.value;
    glyph.source = g.source;
    glyph.strikePpem = g.strikePpem;
    glyph.imageWidth = image.width;
    glyph.imageHeight = image.height;
    glyph.inflatedNeeded = image.inflatedNeeded;
    glyph.imageNeeded = image.imageNeeded;
    glyph.zlibNeeded = pngZlibScratch;
    if (g.width == 0 || g.height == 0)
        return fontOk(glyph);
    const box = scaled(g, ppem, image);
    if (box.hasError)
        return fontErr!ColourGlyph(box.error);
    glyph.bearingX = box.value.left;
    glyph.bearingY = box.value.top;
    glyph.width = box.value.right - box.value.left;
    glyph.height = box.value.top - box.value.bottom;
    return fontOk(glyph);
}

/**
Draws glyph `gid`'s bitmap scaled to `ppem` into `region` (FTR7): every
pixel of the box `bitmapMeasure` reports is written, premultiplied. The
region and the workspace's `inflated`, `image` and `zlib` arrays must be
at least the sizes `bitmapMeasure` reports; short storage is
`limitExceeded` naming `callerStorage`. The errors of `bitmapMeasure` and
`decodePng` apply, located in the table that holds the PNG. A glyph
without a bitmap draws nothing and reports `source` `none`. Cost: one
PNG decode, then one pass over the image pixels each output pixel covers.
*/
FontResult!ColourGlyph rasterizeBitmapGlyph(scope const Face face, uint gid, Ppem ppem,
    scope ColourRegion region, return scope ColourWorkspace ws)
{
    const measured = bitmapMeasure(face, gid, ppem);
    if (measured.hasError || measured.value.source == ColourSource.none || measured.value.empty)
        return measured;
    ColourGlyph glyph = measured.value;
    ulong needed;
    if (!regionHolds(region, glyph.width, glyph.height, needed))
        return fontErr!ColourGlyph(callerStorageError(needed));
    const g = bitmapGlyph(face, gid, ppem).value;
    const decoded = decodePng(g.png, ws.image, ws.inflated, ws.zlib);
    if (decoded.hasError)
        return fontErr!ColourGlyph(rebase(decoded.error, g.table, g.tableStart, g.pngOffset - g.tableStart));
    const image = decoded.value;
    const box = scaled(g, ppem, image).value;
    resample(region, glyph, box, ws.image[0 .. image.imageNeeded], image.width, image.height);
    return fontOk(glyph);
}

/// The length of the overlap of [a0, a1) and [b0, b1).
private double overlap(double a0, double a1, double b0, double b1)
{
    const lo = a0 > b0 ? a0 : b0, hi = a1 < b1 ? a1 : b1;
    return hi > lo ? hi - lo : 0;
}

/// Box-filters the `width` × `height` RGBA `image` placed per `box` into `region`'s `glyph` box.
private void resample(scope ColourRegion region, in ColourGlyph glyph, in Scaled box,
    scope const(ubyte)[] image, uint width, uint height)
{
    import std.math : floor;

    foreach (y; 0 .. glyph.height)
    {
        // The output row's span in image rows.
        const oy = box.top - y; // the row's top edge, in output pixels up from the baseline
        const v0 = (box.originY - oy) / box.sy, v1 = (box.originY - oy + 1) / box.sy;
        auto row = region.data[y * region.stride .. y * region.stride + 4 * glyph.width];
        foreach (x; 0 .. glyph.width)
        {
            const ox = box.left + x;
            const u0 = (ox - box.originX) / box.sx, u1 = (ox + 1 - box.originX) / box.sx;
            double[4] sum = 0;
            const rowFirst = v0 < 0 ? 0 : cast(uint) floor(v0), colFirst = u0 < 0 ? 0 : cast(uint) floor(u0);
            for (uint iy = rowFirst; iy < height && iy < v1; ++iy)
            {
                const wy = overlap(iy, iy + 1.0, v0, v1);
                if (wy == 0)
                    continue;
                for (uint ix = colFirst; ix < width && ix < u1; ++ix)
                {
                    const w = wy * overlap(ix, ix + 1.0, u0, u1);
                    const p = image[4 * (iy * width + ix) .. 4 * (iy * width + ix) + 4];
                    foreach (c; 0 .. 4)
                        sum[c] += w * p[c];
                }
            }
            // The weights are in image pixels; an output pixel spans 1 / (sx · sy) of them.
            const norm = box.sx * box.sy;
            foreach (c; 0 .. 4)
            {
                const v = sum[c] * norm + 0.5;
                row[4 * x + c] = cast(ubyte)(v >= 255 ? 255 : v);
            }
        }
    }
}
