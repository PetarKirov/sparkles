/**
The PNG decoder of bitmap colour strikes (`docs/specs/font/SPEC.md` FTR7,
FTX4).

`pngHeader` reads a PNG's `IHDR` and says what decoding it needs;
`decodePng` decodes it into a caller-owned premultiplied RGBA image. The
forms emoji fonts use are decoded: 8-bit greyscale, greyscale with alpha,
RGB and RGBA, and indexed colour at 1, 2, 4 or 8 bits, all five scanline
filters, and `tRNS` transparency. Interlaced, 16-bit and other forms are
`unsupportedVersion`. Chunk CRCs are not checked; the zlib stream's own
Adler-32 checksum is.

Inflation is Phobos's zlib (`etc.c.zlib`, inside `libphobos2`, so no
library joins the link line), allocating only from the caller's
`zlibScratch` of `pngZlibScratch` bytes. That keeps it referentially
transparent, which is why the call into it is treated as `pure`.

Errors carry offsets from the start of the PNG and no table; the strike
reader rebases them onto the table that holds the PNG.
*/
module sparkles.font.png;

import sparkles.font.bytes : be32, fits;
import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontResult, fontErr,
    fontOk, Tag;

import core.checkedint : addu, mulu;

// ---------------------------------------------------------------------------
// Inflate over the caller's scratch
// ---------------------------------------------------------------------------

/// What the zlib call reads and writes.
private struct InflateJob
{
    const(ubyte)[] chunks; // the run of IDAT chunks, headers and CRCs included
    ubyte[] output;
    ubyte[] scratch;
    size_t produced;
}

/**
Inflates the `IDAT` bodies of `chunks` into `output`, allocating from
`scratch` only, and returns how many bytes it wrote; fewer than
`output.length` when the stream is corrupt or short.

zlib with a caller-supplied allocator reads nothing but its arguments and
writes nothing but `output` and `scratch`, so the call is pure in fact;
the cast says so to the type system.
*/
private size_t inflateData(scope const(ubyte)[] chunks, scope ubyte[] output, scope ubyte[] scratch)
    @trusted pure nothrow @nogc
{
    alias Pure = void function(InflateJob*) pure nothrow @nogc;
    auto job = InflateJob(chunks, output, scratch);
    (cast(Pure) &inflateJob)(&job);
    return job.produced;
}

private struct Bump
{
    ubyte* base;
    size_t length, used;
}

private extern (C) void* bumpAlloc(void* opaque, uint items, uint size) @system nothrow @nogc
{
    auto bump = cast(Bump*) opaque;
    const bytes = (ulong(items) * size + 15) & ~15UL;
    if (bytes > bump.length - bump.used)
        return null;
    auto p = bump.base + bump.used;
    bump.used += cast(size_t) bytes;
    return p;
}

private extern (C) void bumpFree(void*, void*) @system nothrow @nogc
{
}

private void inflateJob(InflateJob* job) @system nothrow @nogc
{
    import etc.c.zlib : inflate, inflateEnd, inflateInit, Z_NO_FLUSH, Z_OK, Z_STREAM_END, z_stream;

    // Align the bump allocator's base.
    const misalign = cast(size_t) job.scratch.ptr & 15;
    const skip = misalign ? 16 - misalign : 0;
    if (skip >= job.scratch.length)
        return;
    auto bump = Bump(job.scratch.ptr + skip, job.scratch.length - skip, 0);
    z_stream s;
    s.zalloc = &bumpAlloc;
    s.zfree = &bumpFree;
    s.opaque = &bump;
    s.next_out = job.output.ptr;
    s.avail_out = cast(uint) job.output.length;
    if (inflateInit(&s) != Z_OK)
        return;
    size_t pos;
    int status = Z_OK;
    while (pos + 12 <= job.chunks.length && status == Z_OK && s.avail_out > 0)
    {
        const length = be32(job.chunks, pos);
        if (Tag(be32(job.chunks, pos + 4)) == idat)
        {
            s.next_in = job.chunks.ptr + pos + 8;
            s.avail_in = length;
            status = inflate(&s, Z_NO_FLUSH);
            if (status != Z_OK && status != Z_STREAM_END)
                break;
        }
        pos += 12 + length;
    }
    // A stream that stops short of its end marker, or a corrupt one, loses its count.
    job.produced = status == Z_STREAM_END || status == Z_OK && s.avail_out == 0
        ? job.output.length - s.avail_out : 0;
    inflateEnd(&s);
}

@safe pure nothrow @nogc:

/// The bytes of zlib scratch `decodePng` needs: its inflate state and a 32 KiB window.
enum size_t pngZlibScratch = 48 * 1024;

/// A PNG's form and the storage decoding it needs.
struct PngImage
{
    /// The image size in pixels.
    uint width, height;
    /// The `IHDR` bit depth and colour type.
    ubyte bitDepth, colourType;
    /// Bytes of the filtered scanlines: `height` rows of a filter byte and the row's samples.
    size_t inflatedNeeded;
    /// Bytes of the RGBA output: `4 · width · height`.
    size_t imageNeeded;
}

private immutable ubyte[8] signature = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'];

private enum Tag ihdr = Tag("IHDR"), plte = Tag("PLTE"), trns = Tag("tRNS"), idat = Tag("IDAT"),
    iend = Tag("IEND");

private FontError at(FontErrorKind kind, ulong offset) => FontError(kind, Tag.init, offset);

/// Samples per pixel of `colourType`.
private uint channels(ubyte colourType)
{
    switch (colourType)
    {
        case 2: return 3;
        case 4: return 2;
        case 6: return 4;
        default: return 1;
    }
}

/// Whether `colourType` at `bitDepth` is a form `decodePng` decodes.
private bool supported(ubyte colourType, ubyte bitDepth)
{
    if (colourType == 3)
        return bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8;
    return bitDepth == 8 && (colourType == 0 || colourType == 2 || colourType == 4 || colourType == 6);
}

/**
The form of `png` and the storage `decodePng` needs for it, from its
signature and `IHDR`. A missing signature or `IHDR`, or a zero dimension,
is `badValue`; a short header is `truncated`; interlacing, a bit depth
other than 8 (1, 2 and 4 too for indexed colour), or an unknown
compression or filter method is `unsupportedVersion`; storage needs past
`size_t` are `arithmeticExhausted`. O(1).
*/
FontResult!PngImage pngHeader(scope const(ubyte)[] png)
{
    if (png.length < 8 + 8 + 13)
        return fontErr!PngImage(at(FontErrorKind.truncated, png.length));
    if (png[0 .. 8] != signature[])
        return fontErr!PngImage(at(FontErrorKind.badValue, 0));
    if (be32(png, 8) != 13 || Tag(be32(png, 12)) != ihdr)
        return fontErr!PngImage(at(FontErrorKind.badValue, 8));
    PngImage image;
    image.width = be32(png, 16);
    image.height = be32(png, 20);
    image.bitDepth = png[24];
    image.colourType = png[25];
    if (image.width == 0 || image.height == 0 || image.width > int.max || image.height > int.max)
        return fontErr!PngImage(at(FontErrorKind.badValue, 16));
    if (!supported(image.colourType, image.bitDepth))
        return fontErr!PngImage(at(FontErrorKind.unsupportedVersion, 24));
    if (png[26] != 0 || png[27] != 0)
        return fontErr!PngImage(at(FontErrorKind.unsupportedVersion, 26));
    if (png[28] != 0)
        return fontErr!PngImage(at(FontErrorKind.unsupportedVersion, 28));
    bool overflow;
    const rowBits = mulu(ulong(image.width), ulong(channels(image.colourType) * image.bitDepth), overflow);
    const inflated = mulu(addu(rowBits / 8 + (rowBits % 8 != 0), 1, overflow), ulong(image.height), overflow);
    const rgba = mulu(mulu(ulong(image.width), ulong(image.height), overflow), 4, overflow);
    if (overflow || inflated > size_t.max || rgba > size_t.max || inflated > uint.max)
        return fontErr!PngImage(at(FontErrorKind.arithmeticExhausted, 16));
    image.inflatedNeeded = cast(size_t) inflated;
    image.imageNeeded = cast(size_t) rgba;
    return fontOk(image);
}

/// The chunks after `IHDR`: the palette, the transparency chunk and the run of `IDAT` chunks.
private struct Chunks
{
    const(ubyte)[] palette, transparency;
    /// Where the first `IDAT` chunk starts, and where the run of them ends.
    size_t dataStart, dataEnd;
}

private FontResult!Chunks chunks(return scope const(ubyte)[] png, in PngImage image)
{
    Chunks c;
    size_t pos = 8 + 8 + 13 + 4;
    bool sawData, dataEnded;
    while (true)
    {
        if (!fits(png.length, pos, 8))
            return fontErr!Chunks(at(FontErrorKind.truncated, png.length));
        const length = be32(png, pos);
        const tag = Tag(be32(png, pos + 4));
        if (!fits(png.length, pos + 8, ulong(length) + 4))
            return fontErr!Chunks(at(FontErrorKind.truncated, png.length));
        if (tag == iend)
            break;
        if (tag == idat)
        {
            // The data chunks must be consecutive.
            if (dataEnded)
                return fontErr!Chunks(at(FontErrorKind.badValue, pos));
            if (!sawData)
                c.dataStart = pos;
            sawData = true;
            c.dataEnd = pos + 12 + length;
        }
        else
        {
            dataEnded = sawData;
            if (tag == plte)
            {
                if (length % 3 != 0 || length == 0 || length > 3 * 256)
                    return fontErr!Chunks(at(FontErrorKind.badValue, pos));
                c.palette = png[pos + 8 .. pos + 8 + length];
            }
            else if (tag == trns)
                c.transparency = png[pos + 8 .. pos + 8 + length];
            else if (tag == ihdr)
                return fontErr!Chunks(at(FontErrorKind.badValue, pos));
        }
        pos += 12 + length;
    }
    if (!sawData)
        return fontErr!Chunks(at(FontErrorKind.badValue, pos));
    if (image.colourType == 3 && c.palette.length == 0)
        return fontErr!Chunks(at(FontErrorKind.badValue, pos));
    return fontOk(c);
}

/**
Decodes `png` into `rgba`: `width · height` pixels of premultiplied RGBA,
rows top to bottom with no padding, alpha associated by
`round(c · a / 255)`. `inflated` holds the filtered scanlines and
`zlibScratch` the inflate state: each must be at least the length
`pngHeader` and `pngZlibScratch` state, and a shorter one is
`limitExceeded` naming `callerStorage`.

The errors of `pngHeader` apply. A missing palette for indexed colour, a
palette index past the palette, non-consecutive `IDAT` chunks, an unknown
filter type, or a zlib stream that is corrupt or yields fewer bytes than
the image is `badValue`; a chunk running past the data is `truncated`.
Cost: one pass of inflate over the `IDAT` data, then one over
`inflatedNeeded` bytes and one over the pixels.
*/
FontResult!PngImage decodePng(scope const(ubyte)[] png, scope ubyte[] rgba, scope ubyte[] inflated,
    scope ubyte[] zlibScratch)
{
    const header = pngHeader(png);
    if (header.hasError)
        return header;
    PngImage image = header.value;
    if (rgba.length < image.imageNeeded)
        return fontErr!PngImage(callerStorageError(image.imageNeeded));
    if (inflated.length < image.inflatedNeeded)
        return fontErr!PngImage(callerStorageError(image.inflatedNeeded));
    if (zlibScratch.length < pngZlibScratch)
        return fontErr!PngImage(callerStorageError(pngZlibScratch));
    const found = chunks(png, image);
    if (found.hasError)
        return fontErr!PngImage(found.error);
    const c = found.value;

    auto scanlines = inflated[0 .. image.inflatedNeeded];
    const produced = inflateData(png[c.dataStart .. c.dataEnd], scanlines, zlibScratch[0 .. pngZlibScratch]);
    if (produced != scanlines.length)
        return fontErr!PngImage(at(FontErrorKind.badValue, c.dataStart));

    const rowBytes = scanlines.length / image.height - 1;
    const bpp = (channels(image.colourType) * image.bitDepth + 7) / 8;
    foreach (y; 0 .. image.height)
    {
        const rowAt = y * (rowBytes + 1);
        const filter = scanlines[rowAt];
        auto row = scanlines[rowAt + 1 .. rowAt + 1 + rowBytes];
        const(ubyte)[] previous = y == 0 ? null : scanlines[rowAt - rowBytes .. rowAt];
        if (!unfilter(filter, row, previous, bpp))
            return fontErr!PngImage(at(FontErrorKind.badValue, c.dataStart));
    }
    if (!expand(image, c, scanlines, rowBytes, rgba[0 .. image.imageNeeded]))
        return fontErr!PngImage(at(FontErrorKind.badValue, c.dataStart));
    return fontOk(image);
}

/// Reverses scanline filter `filter` on `row` in place, given the already reversed `previous` row.
private bool unfilter(ubyte filter, scope ubyte[] row, scope const(ubyte)[] previous, size_t bpp)
{
    ubyte up(size_t i) => previous.length ? previous[i] : 0;
    ubyte left(size_t i) => i >= bpp ? row[i - bpp] : 0;
    ubyte upLeft(size_t i) => i >= bpp && previous.length ? previous[i - bpp] : 0;
    switch (filter)
    {
        case 0:
            return true;
        case 1:
            foreach (i; bpp .. row.length)
                row[i] = cast(ubyte)(row[i] + row[i - bpp]);
            return true;
        case 2:
            if (previous.length)
                foreach (i; 0 .. row.length)
                    row[i] = cast(ubyte)(row[i] + previous[i]);
            return true;
        case 3:
            foreach (i; 0 .. row.length)
                row[i] = cast(ubyte)(row[i] + (uint(left(i)) + up(i)) / 2);
            return true;
        case 4:
            foreach (i; 0 .. row.length)
            {
                const a = int(left(i)), b = int(up(i)), c = int(upLeft(i));
                const p = a + b - c;
                const pa = abs(p - a), pb = abs(p - b), pc = abs(p - c);
                const predictor = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
                row[i] = cast(ubyte)(row[i] + predictor);
            }
            return true;
        default:
            return false;
    }
}

private int abs(int v) => v < 0 ? -v : v;

private ubyte premultiply(uint channel, uint alpha) => cast(ubyte)((channel * alpha + 127) / 255);

/// Expands the reversed scanlines into premultiplied RGBA; false for a palette index past the palette.
private bool expand(in PngImage image, in Chunks c, scope const(ubyte)[] scanlines, size_t rowBytes,
    scope ubyte[] rgba)
{
    const t = c.transparency;
    // tRNS for greyscale and RGB names one 16-bit colour; at 8 bits only its low byte can match.
    const bool keyed = (image.colourType == 0 && t.length >= 2 && t[0] == 0)
        || (image.colourType == 2 && t.length >= 6 && t[0] == 0 && t[2] == 0 && t[4] == 0);
    const paletteEntries = c.palette.length / 3;
    foreach (y; 0 .. image.height)
    {
        const row = scanlines[y * (rowBytes + 1) + 1 .. (y + 1) * (rowBytes + 1)];
        auto out_ = rgba[4 * y * image.width .. 4 * (y + 1) * image.width];
        foreach (x; 0 .. image.width)
        {
            uint r, g, b, a = 255;
            final switch (image.colourType)
            {
                case 0:
                    r = g = b = row[x];
                    if (keyed && row[x] == t[1])
                        a = 0;
                    break;
                case 2:
                    r = row[3 * x]; g = row[3 * x + 1]; b = row[3 * x + 2];
                    if (keyed && r == t[1] && g == t[3] && b == t[5])
                        a = 0;
                    break;
                case 3:
                {
                    const depth = image.bitDepth;
                    const bit = x * depth;
                    const index = (row[bit / 8] >> (8 - depth - bit % 8)) & ((1 << depth) - 1);
                    if (index >= paletteEntries)
                        return false;
                    r = c.palette[3 * index]; g = c.palette[3 * index + 1]; b = c.palette[3 * index + 2];
                    if (index < t.length)
                        a = t[index];
                    break;
                }
                case 4:
                    r = g = b = row[2 * x];
                    a = row[2 * x + 1];
                    break;
                case 6:
                    r = row[4 * x]; g = row[4 * x + 1]; b = row[4 * x + 2]; a = row[4 * x + 3];
                    break;
            }
            out_[4 * x] = premultiply(r, a);
            out_[4 * x + 1] = premultiply(g, a);
            out_[4 * x + 2] = premultiply(b, a);
            out_[4 * x + 3] = cast(ubyte) a;
        }
    }
    return true;
}
