/**
PNG files, read and written: the project's one PNG codec.

`pngHeader` reads a PNG's signature and `IHDR` and says what decoding it
needs; `decodePng` decodes it into caller-owned storage as 8-bit RGBA,
straight or premultiplied. Every colour type is decoded, at every bit depth
the format allows, with `tRNS` transparency and Adam7 interlacing. The
decoder allocates nothing: the pixels, the filtered scanlines and zlib's
state all live in storage the caller passes, sized by `pngHeader` and
$(LREF pngZlibScratch). `decodePngAlloc` is the allocating convenience.

It decodes as stb_image does, so the raylib arm's pixels did not change when
it stopped using stb_image for kitty graphics: chunk checksums are not
checked (the zlib stream's Adler-32 is), 16-bit samples keep their high
byte, and sub-byte greyscale scales to the full range. A differential test
holds the two to the same bytes over PngSuite
(`sparkles.ui_raylib.png_oracle`); the colour strikes of emoji fonts decode
through it too (`sparkles.font.png`).

Decoding is bounded by the image it declares: the inflated stream must be
exactly as long as the header says, so a small file cannot expand past its
storage, and an image over $(LREF maxPngPixels) is refused.

The encoder writes 8-bit RGBA as the smallest file that is still a valid
PNG — one `IDAT` of unfiltered rows — because its users (a screenshot, a
test capture) are read, never streamed.

Inflation is Phobos's zlib (`etc.c.zlib`, inside `libphobos2`, so no
library joins the link line), allocating only from the caller's scratch.
That keeps it referentially transparent, which is why the call into it is
treated as `pure`.
*/
module sparkles.image.png;

import sparkles.base.text.errors : NoGcHook;

import expected : Expected, err, ok;

/// The largest image decoded, in pixels: 256 MiB of RGBA.
enum ulong maxPngPixels = 1UL << 26;

/// The bytes of zlib scratch `decodePng` needs: its inflate state and a 32 KiB window.
enum size_t pngZlibScratch = 48 * 1024;

/// Why a PNG was not decoded.
enum PngErrorKind : ubyte
{
    /// The file ends inside its signature, its header or a chunk, or before `IEND`.
    truncated,
    /// The file breaks the format: a bad signature, chunk order or value,
    /// a corrupt or overlong zlib stream, a palette index past the palette.
    malformed,
    /// A form the format does not define: an unknown colour type, bit
    /// depth, compression, filter or interlace method.
    unsupported,
    /// The image is larger than $(LREF maxPngPixels).
    tooLarge,
    /// A caller-owned array is shorter than `needed`.
    callerStorage,
}

/// A refusal, located in the file.
struct PngError
{
    /// What went wrong.
    PngErrorKind kind;
    /// The offset from the start of the file that the refusal concerns.
    ulong offset;
    /// For `callerStorage`, the array length decoding needs; otherwise 0.
    ulong needed;
}

/// The result of a fallible PNG operation.
alias PngResult(T) = Expected!(T, PngError, NoGcHook);

/// How decoded pixels carry alpha.
enum Alpha : ubyte
{
    /// Colour as the file stores it, alpha beside it.
    straight,
    /// Colour multiplied by alpha: `round(c · a / 255)`.
    premultiplied,
}

/// A PNG's form and the storage decoding it needs.
struct PngImage
{
    /// The image size in pixels.
    uint width, height;
    /// The `IHDR` bit depth and colour type.
    ubyte bitDepth, colourType;
    /// Whether the rows are stored in Adam7's seven passes.
    bool interlaced;
    /// Bytes of the filtered scanlines: every pass's rows, each led by its filter byte.
    size_t inflatedNeeded;
    /// Bytes of the RGBA output: `4 · width · height`.
    size_t imageNeeded;
}

/// A decoded image: its size and its RGBA pixels.
struct DecodedPng
{
    /// The image size in pixels.
    uint width, height;
    /// `4 · width · height` bytes of RGBA, rows top to bottom.
    ubyte[] rgba;
}

@safe pure nothrow @nogc
{
    /**
    The form of `png` and the storage `decodePng` needs for it, from its
    signature and `IHDR`. A missing signature or `IHDR`, or a zero
    dimension, is `malformed`; a short header is `truncated`; a colour type,
    bit depth, compression, filter or interlace method the format does not
    define is `unsupported`; an image over $(LREF maxPngPixels) is
    `tooLarge`. O(1).
    */
    PngResult!PngImage pngHeader(scope const(ubyte)[] png)
    {
        if (png.length < 8 + 8 + 13)
            return fail!PngImage(PngErrorKind.truncated, png.length);
        if (png[0 .. 8] != signature[])
            return fail!PngImage(PngErrorKind.malformed, 0);
        if (be32(png, 8) != 13 || png[12 .. 16] != "IHDR")
            return fail!PngImage(PngErrorKind.malformed, 8);
        PngImage image;
        image.width = be32(png, 16);
        image.height = be32(png, 20);
        image.bitDepth = png[24];
        image.colourType = png[25];
        if (image.width == 0 || image.height == 0 || image.width > int.max || image.height > int.max)
            return fail!PngImage(PngErrorKind.malformed, 16);
        if (!depthAllowed(image.colourType, image.bitDepth))
            return fail!PngImage(PngErrorKind.unsupported, 24);
        if (png[26] != 0 || png[27] != 0)
            return fail!PngImage(PngErrorKind.unsupported, 26);
        if (png[28] > 1)
            return fail!PngImage(PngErrorKind.unsupported, 28);
        image.interlaced = png[28] == 1;
        if (ulong(image.width) * image.height > maxPngPixels)
            return fail!PngImage(PngErrorKind.tooLarge, 16);

        // At most 2^26 pixels of at most 8 bytes: no sum below overflows.
        ulong inflated;
        foreach (p; passes(image))
            if (p.width && p.height)
                inflated += (rowBytes(p.width, image) + 1) * ulong(p.height);
        image.inflatedNeeded = cast(size_t) inflated;
        image.imageNeeded = cast(size_t)(ulong(image.width) * image.height * 4);
        return ok!(PngError, NoGcHook)(image);
    }

    /**
    Decodes `png` into `rgba`: `width · height` pixels of 8-bit RGBA, rows
    top to bottom with no padding, alpha as `alpha` says. `inflated` holds
    the filtered scanlines and `zlibScratch` the inflate state: each must be
    at least the length `pngHeader` and $(LREF pngZlibScratch) state, and a
    shorter one is `callerStorage`, naming the length it needs.

    The errors of `pngHeader` apply. A second `IHDR`, a misplaced or
    repeated `PLTE` or `tRNS`, a `tRNS` of the wrong length for the colour
    type, an unknown critical chunk, `IDAT` chunks that are not
    consecutive, a missing palette for indexed colour or an index past it,
    an unknown filter type, or a zlib stream that is corrupt or yields other
    than exactly the scanlines is `malformed`; a file ending before `IEND`
    is `truncated`. Cost: one pass of inflate over the `IDAT` data, then one
    over `inflatedNeeded` bytes and one over the pixels.
    */
    PngResult!PngImage decodePng(scope const(ubyte)[] png, scope ubyte[] rgba, scope ubyte[] inflated,
        scope ubyte[] zlibScratch, Alpha alpha = Alpha.straight)
    {
        const header = pngHeader(png);
        if (header.hasError)
            return header;
        const image = header.value;
        if (rgba.length < image.imageNeeded)
            return storage!PngImage(image.imageNeeded);
        if (inflated.length < image.inflatedNeeded)
            return storage!PngImage(image.inflatedNeeded);
        if (zlibScratch.length < pngZlibScratch)
            return storage!PngImage(pngZlibScratch);
        const found = chunks(png, image);
        if (found.hasError)
            return fail!PngImage(found.error.kind, found.error.offset);
        const c = found.value;

        auto scanlines = inflated[0 .. image.inflatedNeeded];
        if (!inflateData(png[c.dataStart .. c.dataEnd], scanlines, zlibScratch[0 .. pngZlibScratch]))
            return fail!PngImage(PngErrorKind.malformed, c.dataStart);

        const bpp = (channels(image.colourType) * image.bitDepth + 7) / 8;
        size_t at;
        foreach (p; passes(image))
        {
            if (!p.width || !p.height)
                continue;
            const stride = cast(size_t) rowBytes(p.width, image);
            foreach (y; 0 .. p.height)
            {
                auto row = scanlines[at + 1 .. at + 1 + stride];
                const(ubyte)[] previous = y == 0 ? null : scanlines[at - stride .. at];
                if (!unfilter(scanlines[at], row, previous, bpp))
                    return fail!PngImage(PngErrorKind.malformed, c.dataStart);
                if (!expandRow(row, p, y, image, c, rgba[0 .. image.imageNeeded], alpha))
                    return fail!PngImage(PngErrorKind.malformed, c.dataStart);
                at += stride + 1;
            }
        }
        return header;
    }
}

/**
Decodes `png` into newly allocated pixels, with the errors of `decodePng`:
for callers off the `@nogc` path, such as a test, an image file or a
terminal's kitty graphics.
*/
PngResult!DecodedPng decodePngAlloc(scope const(ubyte)[] png, Alpha alpha = Alpha.straight)
    @safe pure nothrow
{
    const header = pngHeader(png);
    if (header.hasError)
        return fail!DecodedPng(header.error.kind, header.error.offset);
    auto rgba = new ubyte[header.value.imageNeeded];
    auto inflated = new ubyte[header.value.inflatedNeeded];
    auto zlib = new ubyte[pngZlibScratch];
    const r = decodePng(png, rgba, inflated, zlib, alpha);
    if (r.hasError)
        return fail!DecodedPng(r.error.kind, r.error.offset);
    return ok!(PngError, NoGcHook)(DecodedPng(header.value.width, header.value.height, rgba));
}

/// The PNG file of `width`×`height` RGBA pixels in `rgba`, rows top to bottom.
ubyte[] encodePng(scope const(ubyte)[] rgba, uint width, uint height) @safe
in (rgba.length == size_t(width) * height * 4, "the pixels must fill the image exactly")
{
    import std.zlib : compress;

    // Every row starts with its filter type: 0, none.
    auto raw = new ubyte[(size_t(width) * 4 + 1) * height];
    foreach (y; 0 .. height)
    {
        const row = size_t(y) * (width * 4 + 1);
        raw[row] = 0;
        raw[row + 1 .. row + 1 + width * 4] = rgba[size_t(y) * width * 4 .. size_t(y + 1) * width * 4];
    }

    ubyte[] png = signature.dup;
    ubyte[13] header;
    header[0 .. 4] = bigEndian(width);
    header[4 .. 8] = bigEndian(height);
    header[8 .. 13] = [8, 6, 0, 0, 0]; // 8 bits, RGBA, deflate, no filter, no interlace
    chunk(png, "IHDR", header[]);
    // `std.zlib` is `@system` only for its `void[]` interface.
    chunk(png, "IDAT", (() @trusted => compress(raw))());
    chunk(png, "IEND", null);
    return png;
}

private:

immutable ubyte[8] signature = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'];

// A chunk: its length, its type, its data, and the CRC-32 of type and data.
void chunk(ref ubyte[] png, string type, scope const(ubyte)[] data) @safe
{
    import std.digest.crc : CRC32;

    png ~= bigEndian(cast(uint) data.length);
    const start = png.length;
    png ~= cast(const(ubyte)[]) type;
    png ~= data;
    CRC32 crc;
    crc.put(png[start .. $]);
    const sum = crc.finish(); // least significant byte first
    png ~= [sum[3], sum[2], sum[1], sum[0]];
}

// ---------------------------------------------------------------------------
// Inflate over the caller's scratch
// ---------------------------------------------------------------------------

// What the zlib call reads and writes.
struct InflateJob
{
    const(ubyte)[] chunks; // the run of IDAT chunks, headers and CRCs included
    ubyte[] output;
    ubyte[] scratch;
    bool exact;
}

/*
Inflates the `IDAT` bodies of `chunks` into exactly `output`, allocating
from `scratch` only: false for a corrupt stream, one that ends short of
`output`, or one with more to give once `output` is full.

zlib with a caller-supplied allocator reads nothing but its arguments and
writes nothing but `output` and `scratch`, so the call is pure in fact; the
cast says so to the type system.
*/
bool inflateData(scope const(ubyte)[] chunks, scope ubyte[] output, scope ubyte[] scratch)
    @trusted pure nothrow @nogc
{
    alias Pure = void function(InflateJob*) pure nothrow @nogc;
    auto job = InflateJob(chunks, output, scratch);
    (cast(Pure) &inflateJob)(&job);
    return job.exact;
}

struct Bump
{
    ubyte* base;
    size_t length, used;
}

extern (C) void* bumpAlloc(void* opaque, uint items, uint size) @system nothrow @nogc
{
    auto bump = cast(Bump*) opaque;
    const bytes = (ulong(items) * size + 15) & ~15UL;
    if (bytes > bump.length - bump.used)
        return null;
    auto p = bump.base + bump.used;
    bump.used += cast(size_t) bytes;
    return p;
}

extern (C) void bumpFree(void*, void*) @system nothrow @nogc
{
}

void inflateJob(InflateJob* job) @system nothrow @nogc
{
    import etc.c.zlib : inflate, inflateEnd, inflateInit, Z_BUF_ERROR, Z_NO_FLUSH, Z_OK, Z_STREAM_END,
        z_stream;

    if (job.output.length > uint.max)
        return;
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
    scope (exit)
        inflateEnd(&s);

    // Once `output` is full, the stream may still hold its end: one more
    // byte would not fit, so a byte written to `sink` is a refusal.
    ubyte sink;
    bool full = job.output.length == 0;
    if (full)
    {
        s.next_out = &sink;
        s.avail_out = 1;
    }
    int status = Z_OK;
    size_t pos;
    while (pos + 12 <= job.chunks.length && status != Z_STREAM_END)
    {
        const length = be32(job.chunks, pos);
        s.next_in = job.chunks.ptr + pos + 8;
        s.avail_in = length;
        while (s.avail_in > 0 && status != Z_STREAM_END)
        {
            status = inflate(&s, Z_NO_FLUSH);
            if (status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR)
                return;
            if (s.avail_out == 0)
            {
                if (full)
                    return;
                full = true;
                s.next_out = &sink;
                s.avail_out = 1;
            }
            else if (status == Z_BUF_ERROR)
                return;
        }
        pos += 12 + length;
    }
    job.exact = status == Z_STREAM_END && s.total_out == job.output.length;
}

// ---------------------------------------------------------------------------
// Chunks, rows and pixels
// ---------------------------------------------------------------------------

@safe pure nothrow @nogc:

PngResult!T fail(T)(PngErrorKind kind, ulong offset) => err!(T, NoGcHook)(PngError(kind, offset));

PngResult!T storage(T)(ulong needed)
    => err!(T, NoGcHook)(PngError(PngErrorKind.callerStorage, 0, needed));

ubyte[4] bigEndian(uint v)
    => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

uint be32(scope const(ubyte)[] b, size_t at)
    => (uint(b[at]) << 24) | (uint(b[at + 1]) << 16) | (uint(b[at + 2]) << 8) | b[at + 3];

// Samples per pixel of `colourType`, or 0 for one the format does not define.
uint channels(int colourType)
{
    switch (colourType)
    {
        case 0, 3: return 1;
        case 4: return 2;
        case 2: return 3;
        case 6: return 4;
        default: return 0;
    }
}

bool depthAllowed(int colourType, int bitDepth)
{
    switch (colourType)
    {
        case 0: return bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8 || bitDepth == 16;
        case 3: return bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8;
        case 2, 4, 6: return bitDepth == 8 || bitDepth == 16;
        default: return false;
    }
}

// The bytes of one row of `width` pixels, without its filter byte.
ulong rowBytes(uint width, in PngImage image)
    => (ulong(width) * channels(image.colourType) * image.bitDepth + 7) / 8;

// One pass of the image: where its pixels land, and how many there are.
struct Pass
{
    uint x0, y0, dx, dy;
    uint width, height;
}

// The seven Adam7 passes, or the one pass of a plain image.
Pass[7] passes(in PngImage image)
{
    Pass[7] result;
    if (!image.interlaced)
    {
        result[0] = Pass(0, 0, 1, 1, image.width, image.height);
        return result;
    }
    static immutable uint[4][7] adam7 = [
        [0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4],
        [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2],
    ];
    foreach (i, a; adam7)
        result[i] = Pass(a[0], a[1], a[2], a[3],
            image.width > a[0] ? (image.width - a[0] + a[2] - 1) / a[2] : 0,
            image.height > a[1] ? (image.height - a[1] + a[3] - 1) / a[3] : 0);
    return result;
}

// The chunks after `IHDR`: the palette, the transparency chunk and the run of `IDAT` chunks.
struct Chunks
{
    const(ubyte)[] palette, transparency;
    // Where the first `IDAT` chunk starts, and where the run of them ends.
    size_t dataStart, dataEnd;
}

PngResult!Chunks chunks(return scope const(ubyte)[] png, in PngImage image)
{
    Chunks c;
    size_t pos = 8 + 8 + 13 + 4;
    bool sawData, dataEnded;
    while (true)
    {
        if (pos > png.length || png.length - pos < 8)
            return fail!Chunks(PngErrorKind.truncated, png.length);
        const length = be32(png, pos);
        if (ulong(length) + 4 > png.length - pos - 8)
            return fail!Chunks(PngErrorKind.truncated, png.length);
        const type = png[pos + 4 .. pos + 8];
        if (type == "IEND")
            break;
        if (type == "IDAT")
        {
            if (dataEnded)
                return fail!Chunks(PngErrorKind.malformed, pos);
            if (!sawData)
                c.dataStart = pos;
            sawData = true;
            c.dataEnd = pos + 12 + length;
        }
        else
        {
            dataEnded = sawData;
            if (type == "PLTE")
            {
                if (c.palette.length || sawData || length == 0 || length > 3 * 256 || length % 3)
                    return fail!Chunks(PngErrorKind.malformed, pos);
                c.palette = png[pos + 8 .. pos + 8 + length];
            }
            else if (type == "tRNS")
            {
                const wrong = image.colourType == 0 ? length != 2
                    : image.colourType == 2 ? length != 6
                    : image.colourType == 3 ? !c.palette.length || length > c.palette.length / 3
                    : true;
                if (c.transparency.length || sawData || wrong)
                    return fail!Chunks(PngErrorKind.malformed, pos);
                c.transparency = png[pos + 8 .. pos + 8 + length];
            }
            else if (type == "IHDR" || (type[0] >= 'A' && type[0] <= 'Z'))
                return fail!Chunks(PngErrorKind.malformed, pos); // a second header, or an unknown critical chunk
        }
        pos += 12 + length;
    }
    if (!sawData)
        return fail!Chunks(PngErrorKind.malformed, pos);
    // A palette longer than the depth can index is accepted, as stb_image and libpng accept it;
    // an index past the palette is refused where it is read.
    if (image.colourType == 3 && !c.palette.length)
        return fail!Chunks(PngErrorKind.malformed, pos);
    return ok!(PngError, NoGcHook)(c);
}

// Reverses filter `filter` on `row` in place, given the already reversed `previous` row of its pass.
bool unfilter(ubyte filter, scope ubyte[] row, scope const(ubyte)[] previous, size_t bpp)
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
                const int a = left(i), b = up(i), c = upLeft(i);
                const p = a + b - c;
                const pa = p > a ? p - a : a - p, pb = p > b ? p - b : b - p, pc = p > c ? p - c : c - p;
                row[i] = cast(ubyte)(row[i] + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c));
            }
            return true;
        default:
            return false;
    }
}

// One sample at its native depth.
uint sample(scope const(ubyte)[] row, size_t index, int bitDepth)
{
    if (bitDepth == 16)
        return (uint(row[index * 2]) << 8) | row[index * 2 + 1];
    if (bitDepth == 8)
        return row[index];
    const bit = index * bitDepth;
    return (row[bit / 8] >> (8 - bitDepth - bit % 8)) & ((1u << bitDepth) - 1);
}

// A native sample as 8 bits: the high byte of 16, the full range of fewer.
ubyte byteOf(uint v, int bitDepth)
    => bitDepth == 16 ? cast(ubyte)(v >> 8) : bitDepth == 8 ? cast(ubyte) v
        : cast(ubyte)(v * 255 / ((1u << bitDepth) - 1));

ubyte premultiply(uint channel, uint alpha) => cast(ubyte)((channel * alpha + 127) / 255);

// Row `y` of pass `p`, unfiltered, into the image at its pixels; false for
// a palette index past the palette.
bool expandRow(scope const(ubyte)[] row, in Pass p, uint y, in PngImage image, in Chunks c, scope ubyte[] rgba,
    Alpha alpha)
{
    const ch = channels(image.colourType);
    const depth = image.bitDepth;
    const t = c.transparency;
    // A grey or RGB `tRNS` key names one colour at the native depth.
    const keyed = image.colourType == 0 || image.colourType == 2 ? t.length >= 2 : false;
    const key0 = keyed ? (uint(t[0]) << 8) | t[1] : 0;
    const key1 = keyed && t.length >= 6 ? (uint(t[2]) << 8) | t[3] : 0;
    const key2 = keyed && t.length >= 6 ? (uint(t[4]) << 8) | t[5] : 0;
    const paletteEntries = c.palette.length / 3;
    const imageY = p.y0 + y * p.dy;
    foreach (i; 0 .. p.width)
    {
        const o = (size_t(imageY) * image.width + p.x0 + size_t(i) * p.dx) * 4;
        const base = size_t(i) * ch;
        uint r, g, b, a = 255;
        final switch (image.colourType)
        {
            case 0:
                const grey = sample(row, base, depth);
                r = g = b = byteOf(grey, depth);
                if (keyed && grey == key0)
                    a = 0;
                break;
            case 2:
                const sr = sample(row, base, depth), sg = sample(row, base + 1, depth),
                    sb = sample(row, base + 2, depth);
                r = byteOf(sr, depth);
                g = byteOf(sg, depth);
                b = byteOf(sb, depth);
                if (keyed && sr == key0 && sg == key1 && sb == key2)
                    a = 0;
                break;
            case 3:
                const index = sample(row, base, depth);
                if (index >= paletteEntries)
                    return false;
                r = c.palette[3 * index];
                g = c.palette[3 * index + 1];
                b = c.palette[3 * index + 2];
                if (index < t.length)
                    a = t[index];
                break;
            case 4:
                r = g = b = byteOf(sample(row, base, depth), depth);
                a = byteOf(sample(row, base + 1, depth), depth);
                break;
            case 6:
                r = byteOf(sample(row, base, depth), depth);
                g = byteOf(sample(row, base + 1, depth), depth);
                b = byteOf(sample(row, base + 2, depth), depth);
                a = byteOf(sample(row, base + 3, depth), depth);
                break;
        }
        if (alpha == Alpha.premultiplied)
        {
            r = premultiply(r, a);
            g = premultiply(g, a);
            b = premultiply(b, a);
        }
        rgba[o] = cast(ubyte) r;
        rgba[o + 1] = cast(ubyte) g;
        rgba[o + 2] = cast(ubyte) b;
        rgba[o + 3] = cast(ubyte) a;
    }
    return true;
}
