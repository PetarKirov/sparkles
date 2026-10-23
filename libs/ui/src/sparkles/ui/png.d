/**
PNG files, read and written: the toolkit's one PNG codec.

The encoder writes 8-bit RGBA as the smallest file that is still a valid PNG
— one `IDAT` of unfiltered rows, deflated by Phobos' zlib — because its
users (a screenshot, a test capture) are read, never streamed. The decoder
reads what an application is handed (a terminal's kitty graphics, an image
file) into 8-bit RGBA: every colour type, 1- to 16-bit samples, `tRNS`, and
Adam7 interlacing.

It decodes as stb_image does, so the raylib arm's pixels did not change when
it stopped using stb_image for kitty graphics: chunk checksums are not
checked (DEFLATE's own checks still run), 16-bit samples keep their high
byte, sub-byte grey scales to the full range. A differential test holds the
two to the same bytes over PngSuite (`sparkles.ui_raylib.png_oracle`).

Decoding is bounded by the image it declares: the inflated stream must be
exactly as long as the header says, so a small file cannot expand into a
large allocation, and an image over $(LREF maxPngPixels) is refused.
*/
module sparkles.ui.png;

/// The largest image decoded, in pixels: 256 MiB of RGBA.
enum ulong maxPngPixels = 1UL << 26;

/// A PNG's header, as the decoder needs it.
struct PngHeader
{
    uint width;       ///
    uint height;      ///
    ubyte bitDepth;   ///
    ubyte colorType;  ///
    bool interlaced;  /// Adam7

    /// Whether the header describes an image this module decodes.
    bool valid() const @safe pure nothrow @nogc
        => width > 0 && height > 0 && ulong(width) * height <= maxPngPixels
            && channels(colorType) > 0 && depthAllowed(colorType, bitDepth);

    /// The decoded image's size in bytes: 8-bit RGBA.
    size_t rgbaLength() const @safe pure nothrow @nogc => size_t(width) * height * 4;
}

/// The header of `data`, or `PngHeader.init` when it is not a PNG this
/// module decodes.
PngHeader pngHeader(in ubyte[] data) @safe pure nothrow
{
    PngHeader h;
    if (data.length < 33 || data[0 .. 8] != signature[] || data[12 .. 16] != "IHDR"
        || be32(data[8 .. 12]) != 13)
        return PngHeader.init;
    const ihdr = data[16 .. 29];
    if (ihdr[10] != 0 || ihdr[11] != 0 || ihdr[12] > 1)
        return PngHeader.init;
    h = PngHeader(be32(ihdr[0 .. 4]), be32(ihdr[4 .. 8]), ihdr[8], ihdr[9], ihdr[12] == 1);
    return h.valid ? h : PngHeader.init;
}

/**
Decodes `data` into `rgba`, which must be exactly `pngHeader(data).rgbaLength`
bytes. False — with `rgba` unspecified — for a file this module does not
decode, a malformed one, or a mismatched buffer. Never throws.
*/
bool decodePngInto(in ubyte[] data, scope ubyte[] rgba) @safe nothrow
{
    const h = pngHeader(data);
    if (!h.valid || rgba.length != h.rgbaLength)
        return false;

    const(ubyte)[] plte, trns;
    ubyte[] idat;
    bool seenIdat, idatEnded, seenIend;
    size_t pos = 8;
    for (bool first = true; pos + 12 <= data.length; first = false)
    {
        const len = be32(data[pos .. pos + 4]);
        if (len > data.length - pos - 12)
            return false;
        const type = data[pos + 4 .. pos + 8];
        const chunk = data[pos + 8 .. pos + 8 + len];
        pos += 12 + len; // the checksum is not checked, as stb_image does not
        if (type == "IHDR")
        {
            if (!first)
                return false;
        }
        else if (type == "PLTE")
        {
            if (plte.length || seenIdat || len < 3 || len > 768 || len % 3)
                return false;
            plte = chunk.dup; // at most 768 bytes
        }
        else if (type == "tRNS")
        {
            if (trns.length || seenIdat)
                return false;
            if (h.colorType == 0 ? len != 2 : h.colorType == 2 ? len != 6
                    : h.colorType == 3 ? len > plte.length / 3 || !plte.length : true)
                return false;
            trns = chunk.dup;
        }
        else if (type == "IDAT")
        {
            if (idatEnded)
                return false;
            seenIdat = true;
            idat ~= chunk;
        }
        else if (type == "IEND")
        {
            seenIend = true;
            break;
        }
        else if (type[0] >= 'A' && type[0] <= 'Z')
            return false; // an unknown critical chunk
        else if (seenIdat)
            idatEnded = true;
    }
    if (!seenIend || !idat.length)
        return false;
    if (h.colorType == 3 && (plte.length < 3 || plte.length / 3 > (1u << h.bitDepth)))
        return false;

    // The raw scanlines of every pass, each row led by its filter byte.
    const ch = channels(h.colorType);
    size_t rawLength;
    foreach (p; passes(h))
        if (p.width && p.height)
            rawLength += (rowBytes(p.width, ch, h.bitDepth) + 1) * p.height;
    auto raw = new ubyte[rawLength];
    if (!inflateExactly(idat, raw))
        return false;

    const bpp = (ch * h.bitDepth + 7) / 8;
    auto prev = new ubyte[rowBytes(h.width, ch, h.bitDepth)];
    auto cur = new ubyte[prev.length];
    size_t at;
    foreach (p; passes(h))
    {
        if (!p.width || !p.height)
            continue;
        const stride = rowBytes(p.width, ch, h.bitDepth);
        prev[0 .. stride] = 0;
        foreach (y; 0 .. p.height)
        {
            const filter = raw[at];
            if (filter > 4)
                return false;
            unfilter(filter, raw[at + 1 .. at + 1 + stride], prev[0 .. stride],
                cur[0 .. stride], bpp);
            at += stride + 1;
            if (!expandRow(cur[0 .. stride], p.width, h, plte, trns, rgba,
                    p.y0 + y * p.dy, p.x0, p.dx))
                return false;
            auto t = prev;
            prev = cur;
            cur = t;
        }
    }
    return true;
}

/// Decodes `data` into a new RGBA buffer, or `null`.
ubyte[] decodePng(in ubyte[] data, out uint width, out uint height) @safe nothrow
{
    const h = pngHeader(data);
    if (!h.valid)
        return null;
    auto rgba = new ubyte[h.rgbaLength];
    if (!decodePngInto(data, rgba))
        return null;
    width = h.width;
    height = h.height;
    return rgba;
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

immutable ubyte[8] signature = [137, 80, 78, 71, 13, 10, 26, 10];

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

ubyte[4] bigEndian(uint v) @safe pure nothrow @nogc
    => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

uint be32(in ubyte[] b) @safe pure nothrow @nogc
    => (uint(b[0]) << 24) | (uint(b[1]) << 16) | (uint(b[2]) << 8) | b[3];

int channels(int colorType) @safe pure nothrow @nogc
{
    switch (colorType)
    {
        case 0, 3: return 1;
        case 4: return 2;
        case 2: return 3;
        case 6: return 4;
        default: return 0;
    }
}

bool depthAllowed(int colorType, int bitDepth) @safe pure nothrow @nogc
{
    switch (colorType)
    {
        case 0: return bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8
                || bitDepth == 16;
        case 3: return bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8;
        case 2, 4, 6: return bitDepth == 8 || bitDepth == 16;
        default: return false;
    }
}

size_t rowBytes(uint width, int ch, int bitDepth) @safe pure nothrow @nogc
    => (size_t(width) * ch * bitDepth + 7) / 8;

// One pass of the image: where its pixels land, and how many there are.
struct Pass
{
    uint x0, y0, dx, dy;
    uint width, height;
}

// The seven Adam7 passes, or the one pass of a plain image.
Pass[] passes(in PngHeader h) @safe pure nothrow
{
    if (!h.interlaced)
        return [Pass(0, 0, 1, 1, h.width, h.height)];
    static immutable uint[4][7] adam7 = [
        [0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4],
        [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2],
    ];
    Pass[] result;
    foreach (a; adam7)
        result ~= Pass(a[0], a[1], a[2], a[3],
            h.width > a[0] ? (h.width - a[0] + a[2] - 1) / a[2] : 0,
            h.height > a[1] ? (h.height - a[1] + a[3] - 1) / a[3] : 0);
    return result;
}

// Inflates `idat` into exactly `raw`: output beyond it, a stream ending
// short, or a zlib error is a rejection, so the allocation is the image's.
bool inflateExactly(in ubyte[] idat, ubyte[] raw) @trusted nothrow
{
    import etc.c.zlib : inflate, inflateEnd, inflateInit, z_stream, Z_NO_FLUSH, Z_OK,
        Z_STREAM_END;

    if (idat.length > uint.max || raw.length > uint.max)
        return false;
    z_stream strm;
    strm.next_in = idat.ptr;
    strm.avail_in = cast(uint) idat.length;
    strm.next_out = raw.ptr;
    strm.avail_out = cast(uint) raw.length;
    if (inflateInit(&strm) != Z_OK)
        return false;
    scope (exit)
        inflateEnd(&strm);
    for (;;)
    {
        const ret = inflate(&strm, Z_NO_FLUSH);
        if (ret == Z_STREAM_END)
            return strm.total_out == raw.length;
        if (ret != Z_OK || strm.avail_in == 0)
            return false;
        if (strm.avail_out == 0)
        {
            // Full but not at the stream's end: one more byte would not fit.
            ubyte scratch;
            strm.next_out = &scratch;
            strm.avail_out = 1;
            return inflate(&strm, Z_NO_FLUSH) == Z_STREAM_END && strm.avail_out == 1;
        }
    }
}

void unfilter(ubyte filter, in ubyte[] src, in ubyte[] prev, ubyte[] cur, size_t bpp)
    @safe pure nothrow @nogc
{
    foreach (x; 0 .. src.length)
    {
        const int a = x >= bpp ? cur[x - bpp] : 0;
        const int b = prev[x];
        const int c = x >= bpp ? prev[x - bpp] : 0;
        int predictor;
        switch (filter)
        {
            case 0: predictor = 0; break;
            case 1: predictor = a; break;
            case 2: predictor = b; break;
            case 3: predictor = (a + b) / 2; break;
            default: predictor = paeth(a, b, c); break;
        }
        cur[x] = cast(ubyte)(src[x] + predictor);
    }
}

int paeth(int a, int b, int c) @safe pure nothrow @nogc
{
    const p = a + b - c;
    const pa = p > a ? p - a : a - p;
    const pb = p > b ? p - b : b - p;
    const pc = p > c ? p - c : c - p;
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

// One sample at its native depth.
uint sample(in ubyte[] row, size_t index, int bitDepth) @safe pure nothrow @nogc
{
    if (bitDepth == 16)
        return (uint(row[index * 2]) << 8) | row[index * 2 + 1];
    if (bitDepth == 8)
        return row[index];
    const bit = index * bitDepth;
    return (row[bit / 8] >> (8 - bitDepth - bit % 8)) & ((1u << bitDepth) - 1);
}

// A native sample as 8 bits: the high byte of 16, the full range of fewer.
ubyte byteOf(uint v, int bitDepth) @safe pure nothrow @nogc
    => bitDepth == 16 ? cast(ubyte)(v >> 8) : bitDepth == 8 ? cast(ubyte) v
        : cast(ubyte)(v * 255 / ((1u << bitDepth) - 1));

// One unfiltered row of a pass into the image, at row `y`, columns
// `x0, x0 + dx, …`.
bool expandRow(in ubyte[] row, uint width, in PngHeader h, in ubyte[] plte, in ubyte[] trns,
    scope ubyte[] rgba, uint y, uint x0, uint dx) @safe pure nothrow @nogc
{
    const ch = channels(h.colorType);
    const depth = h.bitDepth;
    uint key0, key1, key2; // a grey or RGB `tRNS` key, at the native depth
    const keyed = trns.length >= 2 && (h.colorType == 0 || h.colorType == 2);
    if (keyed)
    {
        key0 = (uint(trns[0]) << 8) | trns[1];
        if (h.colorType == 2)
        {
            key1 = (uint(trns[2]) << 8) | trns[3];
            key2 = (uint(trns[4]) << 8) | trns[5];
        }
    }
    foreach (i; 0 .. width)
    {
        const o = (size_t(y) * h.width + x0 + size_t(i) * dx) * 4;
        const base = size_t(i) * ch;
        final switch (h.colorType)
        {
            case 0:
                const g = sample(row, base, depth);
                rgba[o] = rgba[o + 1] = rgba[o + 2] = byteOf(g, depth);
                rgba[o + 3] = keyed && g == key0 ? 0 : 255;
                break;
            case 2:
                const r = sample(row, base, depth), g = sample(row, base + 1, depth),
                    b = sample(row, base + 2, depth);
                rgba[o] = byteOf(r, depth);
                rgba[o + 1] = byteOf(g, depth);
                rgba[o + 2] = byteOf(b, depth);
                rgba[o + 3] = keyed && r == key0 && g == key1 && b == key2 ? 0 : 255;
                break;
            case 3:
                const index = sample(row, base, depth);
                if (3 * index + 2 >= plte.length)
                    return false;
                rgba[o] = plte[3 * index];
                rgba[o + 1] = plte[3 * index + 1];
                rgba[o + 2] = plte[3 * index + 2];
                rgba[o + 3] = index < trns.length ? trns[index] : 255;
                break;
            case 4:
                rgba[o] = rgba[o + 1] = rgba[o + 2] = byteOf(sample(row, base, depth), depth);
                rgba[o + 3] = byteOf(sample(row, base + 1, depth), depth);
                break;
            case 6:
                foreach (c; 0 .. 4)
                    rgba[o + c] = byteOf(sample(row, base + c, depth), depth);
                break;
        }
    }
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests: PNGs built in memory. The differential test against stb_image over
// PngSuite is `sparkles.ui_raylib.png_oracle`.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    struct ChunkSpec
    {
        string type;
        const(ubyte)[] payload;
        bool badCrc;
    }

    // `scanlines` already carry their filter bytes; `extra` goes after
    // PLTE/tRNS, before IDAT.
    ubyte[] buildPng(uint w, uint h, ubyte colorType, ubyte bitDepth, in ubyte[] scanlines,
        in ubyte[] plte = null, in ubyte[] trns = null, ChunkSpec extra = ChunkSpec.init,
        bool duplicateIhdr = false, bool includeIend = true, bool splitIdat = false,
        bool interlaced = false) @safe
    {
        import std.zlib : compress;

        ubyte[] png = signature.dup;
        void add(string type, in ubyte[] payload, bool badCrc = false)
        {
            chunk(png, type, payload);
            if (badCrc)
                png[$ - 1] ^= 0xFF;
        }

        ubyte[13] ihdr;
        ihdr[0 .. 4] = bigEndian(w);
        ihdr[4 .. 8] = bigEndian(h);
        ihdr[8] = bitDepth;
        ihdr[9] = colorType;
        ihdr[12] = interlaced;
        add("IHDR", ihdr[]);
        if (duplicateIhdr)
            add("IHDR", ihdr[]);
        if (plte.length)
            add("PLTE", plte);
        if (trns.length)
            add("tRNS", trns);
        if (extra.type.length)
            add(extra.type, extra.payload, extra.badCrc);
        const idat = (() @trusted => cast(const(ubyte)[]) compress(scanlines))();
        if (splitIdat && idat.length > 1)
        {
            add("IDAT", idat[0 .. $ / 2]);
            add("IDAT", idat[$ / 2 .. $]);
        }
        else
            add("IDAT", idat);
        if (includeIend)
            add("IEND", null);
        return png;
    }

    ubyte[] decoded(in ubyte[] png) @safe nothrow
    {
        uint w, h;
        return decodePng(png, w, h);
    }
}

@("ui.png.encodeThenDecodeIsTheIdentity")
@safe unittest
{
    const ubyte[] rgba = [1, 2, 3, 4, 250, 240, 230, 220, 9, 8, 7, 0, 0, 0, 0, 255];
    uint w, h;
    assert(decodePng(encodePng(rgba, 2, 2), w, h) == rgba && w == 2 && h == 2);
}

@("ui.png.colourTypesAndDepths")
@safe unittest
{
    assert(decoded(buildPng(2, 1, 6, 8, [0, 10, 20, 30, 40, 250, 240, 230, 220]))
        == [10, 20, 30, 40, 250, 240, 230, 220], "RGBA");
    assert(decoded(buildPng(1, 1, 2, 8, [0, 1, 2, 3])) == [1, 2, 3, 255], "RGB");
    assert(decoded(buildPng(1, 1, 4, 8, [0, 200, 128])) == [200, 200, 200, 128], "grey + alpha");
    assert(decoded(buildPng(1, 1, 0, 16, [0, 0x80, 0xFF])) == [128, 128, 128, 255],
        "16-bit keeps its high byte");
    assert(decoded(buildPng(1, 1, 2, 16, [0, 0x12, 0x34, 0x80, 0x00, 0xFF, 0xFF]))
        == [0x12, 0x80, 0xFF, 255]);
    assert(decoded(buildPng(2, 1, 0, 1, [0, 0x80])) == [255, 255, 255, 255, 0, 0, 0, 255],
        "1-bit grey scales to the full range");
    assert(decoded(buildPng(4, 1, 3, 2, [0, 0x1B], [0, 0, 0, 85, 0, 0, 170, 0, 0, 255, 0, 0]))
        == [0, 0, 0, 255, 85, 0, 0, 255, 170, 0, 0, 255, 255, 0, 0, 255], "2-bit palette");
}

@("ui.png.transparencyKeysAndPaletteAlpha")
@safe unittest
{
    assert(decoded(buildPng(2, 1, 3, 8, [0, 0, 1], [255, 0, 0, 0, 255, 0], [63]))
        == [255, 0, 0, 63, 0, 255, 0, 255]);
    assert(decoded(buildPng(2, 1, 0, 8, [0, 7, 8], null, [0, 7]))
        == [7, 7, 7, 0, 8, 8, 8, 255], "a grey key at the native depth");
    assert(!decoded(buildPng(1, 1, 2, 8, [0, 1, 2, 3], null, [0, 1])).length,
        "an RGB key is six bytes");
}

@("ui.png.everyFilter")
@safe unittest
{
    assert(decoded(buildPng(2, 1, 6, 8, [1, 100, 0, 0, 255, 10, 10, 10, 0]))
        == [100, 0, 0, 255, 110, 10, 10, 255], "sub");
    assert(decoded(buildPng(1, 2, 2, 8, [0, 9, 8, 7, 2, 1, 1, 1]))
        == [9, 8, 7, 255, 10, 9, 8, 255], "up");
    assert(decoded(buildPng(2, 1, 6, 8, [3, 100, 0, 0, 255, 60, 10, 10, 128]))
        == [100, 0, 0, 255, 110, 10, 10, 255], "average");
    assert(decoded(buildPng(2, 2, 2, 8, [0, 100, 0, 0, 0, 100, 0, 4, 10, 10, 0, 10, 10, 0]))
        == [100, 0, 0, 255, 0, 100, 0, 255, 110, 10, 0, 255, 10, 110, 0, 255], "paeth");
    assert(!decoded(buildPng(1, 1, 6, 8, [5, 1, 2, 3, 4])).length, "no filter 5");
}

@("ui.png.adam7PlacesEachPass")
@safe unittest
{
    // A 2×2 grey image has three non-empty passes: 1 holds (0, 0), 6 holds
    // (1, 0), 7 holds the second row.
    assert(decoded(buildPng(2, 2, 0, 8, [0, 10, 0, 20, 0, 30, 40], interlaced: true))
        == [10, 10, 10, 255, 20, 20, 20, 255, 30, 30, 30, 255, 40, 40, 40, 255]);
}

@("ui.png.chunkRules")
@safe unittest
{
    const ubyte[] scan = [0, 1, 2, 3, 4];
    assert(decoded(buildPng(1, 1, 6, 8, scan, null, null, ChunkSpec("tEXt", [1], true))).length,
        "a bad checksum is not checked, as stb_image does not");
    assert(!decoded(buildPng(1, 1, 6, 8, scan, null, null, ChunkSpec("ABCD", [1, 2]))).length,
        "an unknown critical chunk");
    assert(decoded(buildPng(1, 1, 6, 8, scan, null, null, ChunkSpec("abCD", [1, 2]))).length,
        "an unknown ancillary one is skipped");
    assert(!decoded(buildPng(1, 1, 6, 8, scan, null, null, ChunkSpec.init, true)).length,
        "two headers");
    assert(!decoded(buildPng(1, 1, 6, 8, scan, null, null, ChunkSpec.init, false, false)).length,
        "no end");
    assert(decoded(buildPng(1, 1, 2, 8, [0, 1, 2, 3], null, null, ChunkSpec.init, false,
        true, true)) == [1, 2, 3, 255], "data split over two IDAT chunks");
}

@("ui.png.malformedAndHostileInputs")
@safe unittest
{
    assert(!decoded([1, 2, 3]).length);
    const png = buildPng(1, 1, 6, 8, [0, 1, 2, 3, 4]);
    assert(!decoded(png[0 .. $ - 20]).length, "truncated");
    assert(!decoded(buildPng(1, 1, 6, 8, new ubyte[64 * 1024])).length,
        "inflates beyond what the header declares");
    ubyte[4] small;
    assert(!decodePngInto(png, small[0 .. 3]), "a buffer of the wrong size");
}
