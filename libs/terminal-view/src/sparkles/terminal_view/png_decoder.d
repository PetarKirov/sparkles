/**
A PNG decoder for kitty graphics that needs no window: chunk parsing,
filter reconstruction and colour expansion here, DEFLATE through zlib's
streaming `inflate`. It replaces raylib's stb_image wrapper wherever a
pane draws pixels without raylib — the Vulkan arm above all.

Supported: every colour type, 8- and 16-bit samples, sub-byte grey and
palette samples, `tRNS`. Adam7 interlacing is refused, as are bit-depth
and colour combinations the PNG specification forbids.
*/
module sparkles.terminal_view.png_decoder;

import sparkles.ghostty.c : GHOSTTY_SYS_OPT_DECODE_PNG, GhosttyAllocator, GhosttySysImage,
    ghostty_alloc, ghostty_sys_set;

/// A decoded PNG: 8-bit RGBA, row-major, `width * height * 4` bytes.
struct PngImage
{
    uint width;
    uint height;
    ubyte[] rgba;

    /// Whether decoding produced an image at all.
    bool ok() const @safe pure nothrow @nogc => width > 0 && height > 0;
}

/// Decodes `data`, or returns `PngImage.init` when it is not a PNG this
/// module decodes. No exception escapes, for any malformed input.
PngImage decodePng(in ubyte[] data) @system
{
    try
        return decodePngImpl(data);
    catch (Throwable)
        return PngImage.init;
}

private PngImage decodePngImpl(in ubyte[] data) @system
{
    import std.digest.crc : CRC32;

    static immutable sig = [137, 80, 78, 71, 13, 10, 26, 10];
    if (data.length < 8 || data[0 .. 8] != sig[])
        return PngImage.init;

    uint width, height;
    int bitDepth, colorType, interlace = -1;
    ubyte[] idat, plte, trns;
    bool seenPlte, seenTrns, seenIdat, idatEnded, seenIend;
    size_t pos = 8;
    while (pos + 12 <= data.length)
    {
        const len = be32(data[pos .. pos + 4]);
        if (len > data.length || pos + 12 + len > data.length)
            return PngImage.init;
        const type = data[pos + 4 .. pos + 8];
        const chunk = data[pos + 8 .. pos + 8 + len];
        // CRC32 over type+data, stored big-endian after the data.
        CRC32 crc;
        crc.put(type);
        crc.put(chunk);
        const sum = crc.finish(); // least significant byte first
        if (be32(data[pos + 8 + len .. pos + 12 + len]) !=
                ((cast(uint) sum[3] << 24) | (cast(uint) sum[2] << 16) |
                (cast(uint) sum[1] << 8) | sum[0]))
            return PngImage.init;

        if (type == "IHDR")
        {
            // IHDR must be the first chunk (offset 8) and unique.
            if (pos != 8 || len != 13 || chunk[10] != 0 || chunk[11] != 0)
                return PngImage.init;
            width = be32(chunk[0 .. 4]);
            height = be32(chunk[4 .. 8]);
            bitDepth = chunk[8];
            colorType = chunk[9];
            interlace = chunk[12];
        }
        else if (pos == 8)
            return PngImage.init; // first chunk is not IHDR
        else if (type == "PLTE")
        {
            if (seenPlte || seenIdat)
                return PngImage.init;
            if (len < 3 || len > 3 * 256 || len % 3 != 0)
                return PngImage.init;
            seenPlte = true;
            plte = chunk.dup;
        }
        else if (type == "tRNS")
        {
            if (seenTrns || seenIdat)
                return PngImage.init;
            switch (colorType)
            {
                case 0:
                    if (len != 2)
                        return PngImage.init;
                    break;
                case 2:
                    if (len != 6)
                        return PngImage.init;
                    break;
                case 3:
                    if (len > plte.length / 3)
                        return PngImage.init;
                    break;
                case 4, 6:
                    return PngImage.init;
                default:
                    return PngImage.init;
            }
            seenTrns = true;
            trns = chunk.dup;
        }
        else if (type == "IDAT")
        {
            if (idatEnded)
                return PngImage.init; // non-consecutive IDAT
            seenIdat = true;
            idat ~= chunk;
        }
        else if (type == "IEND")
        {
            if (len != 0)
                return PngImage.init;
            seenIend = true;
            break;
        }
        else if (type[0] >= 'A' && type[0] <= 'Z')
            return PngImage.init; // unknown critical chunk
        else if (seenIdat)
            idatEnded = true;
        pos += 12 + len;
    }
    // Adam7 is the one layout this decoder does not reconstruct.
    if (!seenIend || interlace != 0 || width == 0 || height == 0)
        return PngImage.init;
    if (cast(ulong) width * height > 1 << 26 || idat.length == 0)
        return PngImage.init;
    if (idat.length > uint.max)
        return PngImage.init;

    const channels = channelsOf(colorType);
    if (channels == 0 || !depthAllowed(colorType, bitDepth))
        return PngImage.init;
    if (colorType == 3 && (plte.length < 3 || plte.length / 3 > (1u << bitDepth)))
        return PngImage.init;
    // Palette `tRNS` was already checked against the palette seen when it
    // arrived — the spec orders PLTE before tRNS, so a longer palette
    // later in the stream cannot rehabilitate an over-long `tRNS`.

    const scanline = (cast(size_t) width * channels * bitDepth + 7) / 8;
    const expectedRaw = (scanline + 1) * height;
    if (expectedRaw > uint.max)
        return PngImage.init;
    ubyte[] raw;
    try
        raw = new ubyte[expectedRaw];
    catch (Exception)
        return PngImage.init;
    if (!inflateBounded(idat, raw))
        return PngImage.init;

    auto rgba = decodeRows(raw, width, height, scanline, channels, bitDepth,
        colorType, plte, trns);
    if (rgba is null)
        return PngImage.init;
    return PngImage(width, height, rgba);
}

/// Streaming inflate into exactly `raw`: output beyond it, a stream
/// ending short, or any zlib error is a rejection, so a decompression
/// bomb never allocates more than the expected raw size.
private bool inflateBounded(in ubyte[] idat, ubyte[] raw) @system
{
    import etc.c.zlib : Z_NO_FLUSH, Z_OK, Z_STREAM_END, inflate, inflateEnd,
        inflateInit, z_stream;

    z_stream strm;
    strm.next_in = cast(const(ubyte)*) idat.ptr;
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
            break;
        if (ret != Z_OK)
            return false;
        if (strm.avail_out == 0)
        {
            // Exactly full but not at stream end: probe with a scratch
            // byte. Stream end without writing it is a clean exact fit;
            // anything else means the output would exceed `raw`.
            ubyte scratch;
            strm.next_out = &scratch;
            strm.avail_out = 1;
            if (inflate(&strm, Z_NO_FLUSH) != Z_STREAM_END || strm.avail_out != 1)
                return false;
            break;
        }
        if (strm.avail_in == 0)
            return false; // input exhausted before stream end
    }
    return strm.total_out == raw.length;
}

/// Installs the decoder as libghostty's PNG decoder: process-global,
/// before any terminal exists, idempotent.
void installPngDecoder() @system nothrow @nogc
{
    import sparkles.ghostty.c : GHOSTTY_SUCCESS;

    // A failed install would silently break every kitty PNG; the result
    // is asserted rather than reported because this runs before any
    // terminal (and its error surface) exists.
    const res = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG,
        cast(const(void)*) &decode_png_cpu);
    assert(res == GHOSTTY_SUCCESS, "installing the PNG decoder failed");
}

/**
The callback libghostty calls. The decoded pixels are copied into the
allocator the library hands over, which takes ownership of the buffer.
*/
extern (C) bool decode_png_cpu(void* userdata, GhosttyAllocator* allocator,
    const(ubyte)* data, size_t data_len, GhosttySysImage* outImg) nothrow
{
    if (data is null || outImg is null || allocator is null)
        return false;
    try
    {
        auto img = decodePng(data[0 .. data_len]);
        if (!img.ok)
            return false;
        auto pixels = ghostty_alloc(allocator, img.rgba.length);
        if (pixels is null)
            return false;
        import core.stdc.string : memcpy;

        memcpy(pixels, img.rgba.ptr, img.rgba.length);
        outImg.width = img.width;
        outImg.height = img.height;
        outImg.data = pixels;
        outImg.data_len = img.rgba.length;
        return true;
    }
    catch (Throwable)
        return false;
}

private uint be32(in ubyte[] b) @safe pure nothrow @nogc
    => (cast(uint) b[0] << 24) | (cast(uint) b[1] << 16) | (cast(uint) b[2] << 8) | b[3];

private int channelsOf(int colorType) @safe pure nothrow @nogc
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

private bool depthAllowed(int colorType, int bitDepth) @safe pure nothrow @nogc
{
    switch (colorType)
    {
        case 0: return bitDepth == 1 || bitDepth == 2 || bitDepth == 4
                || bitDepth == 8 || bitDepth == 16;
        case 3: return bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8;
        case 2, 4, 6: return bitDepth == 8 || bitDepth == 16;
        default: return false;
    }
}

/// Unfilters and expands one row at a time, so peak memory beyond the
/// output is two scanlines rather than a second full image. Returns
/// `null` on an invalid filter byte or an out-of-palette index.
private ubyte[] decodeRows(in ubyte[] raw, uint width, uint height, size_t scanline,
    int channels, int bitDepth, int colorType, in ubyte[] plte, in ubyte[] trns) @system
{
    ubyte[] rgba, prevRow, curRow;
    try
    {
        rgba = new ubyte[cast(size_t) width * height * 4];
        prevRow = new ubyte[scanline];
        curRow = new ubyte[scanline];
    }
    catch (Exception)
        return null;
    const bpp = (channels * bitDepth + 7) / 8 < 1 ? 1 : (channels * bitDepth + 7) / 8;
    foreach (y; 0 .. height)
    {
        const filter = raw[y * (scanline + 1)];
        if (filter > 4)
            return null;
        const src = raw[y * (scanline + 1) + 1 .. (y + 1) * (scanline + 1)];
        foreach (x; 0 .. scanline)
        {
            const a = x >= bpp ? curRow[x - bpp] : 0;
            const b = prevRow[x];
            const c = x >= bpp ? prevRow[x - bpp] : 0;
            int predictor;
            switch (filter)
            {
                case 0: predictor = 0; break;
                case 1: predictor = a; break;
                case 2: predictor = b; break;
                case 3: predictor = (a + b) / 2; break;
                default: predictor = paeth(a, b, c); break;
            }
            curRow[x] = cast(ubyte)(src[x] + predictor);
        }
        if (!expandRow(curRow, rgba[y * cast(size_t) width * 4 .. (y + 1) * cast(size_t) width * 4],
                width, channels, bitDepth, colorType, plte, trns))
            return null;
        // The row just decoded becomes the previous row; the old buffer
        // is reused as scratch and fully overwritten next row.
        auto tmp = prevRow;
        prevRow = curRow;
        curRow = tmp;
    }
    return rgba;
}

private int paeth(int a, int b, int c) @safe pure nothrow @nogc
{
    const p = a + b - c;
    const pa = p > a ? p - a : a - p;
    const pb = p > b ? p - b : b - p;
    const pc = p > c ? p - c : c - p;
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

private bool expandRow(in ubyte[] row, ubyte[] rgba, uint width,
    int channels, int bitDepth, int colorType, in ubyte[] plte, in ubyte[] trns)
    @safe pure nothrow
{
    ushort[3] trnsSample;
    const hasTrns = trns.length >= 2;
    if (hasTrns && (colorType == 0 || colorType == 2))
        foreach (i; 0 .. channels)
            if (trns.length >= 2 * (i + 1))
                trnsSample[i] = cast(ushort)((trns[2 * i] << 8) | trns[2 * i + 1]);

    // One sample at its native depth, and as an 8-bit value.
    void sample(size_t pixel, int channel, out uint native_, out ubyte byte_)
    {
        if (bitDepth == 16)
        {
            const o = (pixel * channels + channel) * 2;
            native_ = (row[o] << 8) | row[o + 1];
            byte_ = row[o];
        }
        else if (bitDepth == 8)
        {
            native_ = byte_ = row[pixel * channels + channel];
        }
        else
        {
            const bitPos = pixel * bitDepth;
            const bits = row[bitPos / 8] >> (8 - bitDepth - bitPos % 8) & ((1 << bitDepth) - 1);
            native_ = bits;
            byte_ = cast(ubyte)(bits * 255 / ((1 << bitDepth) - 1));
        }
    }

    size_t out_;
    foreach (x; 0 .. width)
    {
        uint n0, n1, n2, n3;
        ubyte b0, b1, b2, b3;
        final switch (colorType)
        {
            case 6:
                sample(x, 0, n0, b0);
                sample(x, 1, n1, b1);
                sample(x, 2, n2, b2);
                sample(x, 3, n3, b3);
                rgba[out_ .. out_ + 4] = [b0, b1, b2, b3];
                break;
            case 2:
                sample(x, 0, n0, b0);
                sample(x, 1, n1, b1);
                sample(x, 2, n2, b2);
                rgba[out_ .. out_ + 4] = [b0, b1, b2,
                    hasTrns && n0 == trnsSample[0] && n1 == trnsSample[1]
                        && n2 == trnsSample[2] ? 0 : 255];
                break;
            case 4:
                sample(x, 0, n0, b0);
                sample(x, 1, n1, b1);
                rgba[out_ .. out_ + 4] = [b0, b0, b0, b1];
                break;
            case 0:
                sample(x, 0, n0, b0);
                rgba[out_ .. out_ + 4] = [b0, b0, b0,
                    hasTrns && n0 == trnsSample[0] ? 0 : 255];
                break;
            case 3:
                sample(x, 0, n0, b0);
                if (3 * n0 + 2 >= plte.length)
                    return false;
                rgba[out_ .. out_ + 4] = [plte[3 * n0], plte[3 * n0 + 1], plte[3 * n0 + 2],
                    n0 < trns.length ? trns[n0] : 255];
                break;
        }
        out_ += 4;
    }
    return true;
}

private struct PngChunkSpec
{
    string type;
    const(ubyte)[] payload;
    bool badCrc;
}

// A PNG built in memory, so the round trip needs no fixture file.
// `trns` and `extraChunk` (emitted before IDAT, after PLTE/tRNS) let
// tests build tRNS, bad-CRC and unknown-chunk streams; `duplicateIhdr`,
// `includeIend` and `splitIdat` shape the chunk sequence.
private ubyte[] buildPng(uint w, uint h, ubyte colorType, ubyte bitDepth,
    in ubyte[] scanlines, in ubyte[] plte = null, in ubyte[] trns = null,
    PngChunkSpec extraChunk = PngChunkSpec.init, bool duplicateIhdr = false,
    bool includeIend = true, bool splitIdat = false) @system
{
    import std.digest.crc : CRC32;
    import std.zlib : compress;

    ubyte[] png = [137, 80, 78, 71, 13, 10, 26, 10];
    void chunk(string type, in ubyte[] payload, bool badCrc = false)
    {
        ubyte[4] head;
        head[0] = cast(ubyte)(payload.length >> 24);
        head[1] = cast(ubyte)(payload.length >> 16);
        head[2] = cast(ubyte)(payload.length >> 8);
        head[3] = cast(ubyte) payload.length;
        png ~= head[];
        const start = png.length;
        png ~= type;
        png ~= payload;
        CRC32 crc;
        crc.put(png[start .. $]);
        const sum = crc.finish();
        png ~= [sum[3], sum[2], sum[1], sum[0]];
        if (badCrc)
            png[$ - 1] ^= 0xFF;
    }

    ubyte[13] ihdr;
    ihdr[3] = cast(ubyte) w;
    ihdr[7] = cast(ubyte) h;
    ihdr[8] = bitDepth;
    ihdr[9] = colorType;
    chunk("IHDR", ihdr[]);
    if (duplicateIhdr)
        chunk("IHDR", ihdr[]);
    if (plte.length)
        chunk("PLTE", plte);
    if (trns.length)
        chunk("tRNS", trns);
    if (extraChunk.type.length)
        chunk(extraChunk.type, extraChunk.payload, extraChunk.badCrc);
    const idat = cast(const(ubyte)[]) compress(scanlines);
    if (splitIdat && idat.length > 1)
    {
        const half = idat.length / 2;
        chunk("IDAT", idat[0 .. half]);
        chunk("IDAT", idat[half .. $]);
    }
    else
        chunk("IDAT", idat);
    if (includeIend)
        chunk("IEND", null);
    return png;
}

@("terminal_view.png_decoder.rgbaAndRgbRoundTrip")
@system unittest
{
    // 2×1 RGBA (filter None), then 1×1 RGB.
    const png = buildPng(2, 1, 6, 8, [0, 10, 20, 30, 40, 250, 240, 230, 220]);
    const img = decodePng(png);
    assert(img.ok && img.width == 2 && img.height == 1);
    assert(img.rgba == [10, 20, 30, 40, 250, 240, 230, 220]);

    const rgb = decodePng(buildPng(1, 1, 2, 8, [0, 1, 2, 3]));
    assert(rgb.rgba == [1, 2, 3, 255]);
}

@("terminal_view.png_decoder.filtersPaletteAnd16Bit")
@system unittest
{
    // Sub filter: second pixel stored as a difference of 10 per channel.
    const sub = decodePng(buildPng(2, 1, 6, 8, [1, 100, 0, 0, 255, 10, 10, 10, 0]));
    assert(sub.rgba == [100, 0, 0, 255, 110, 10, 10, 255]);

    // Up filter on the second row.
    const up = decodePng(buildPng(1, 2, 2, 8, [0, 9, 8, 7, 2, 1, 1, 1]));
    assert(up.rgba == [9, 8, 7, 255, 10, 9, 8, 255]);

    // Palette indices 0 and 1.
    const pal = decodePng(buildPng(2, 1, 3, 8, [0, 0, 1], [255, 0, 0, 0, 255, 0]));
    assert(pal.rgba == [255, 0, 0, 255, 0, 255, 0, 255]);

    // 16-bit samples keep their high byte; grey replicates.
    const deep = decodePng(buildPng(1, 1, 0, 16, [0, 0x80, 0xFF]));
    assert(deep.rgba == [128, 128, 128, 255]);
}

@("terminal_view.png_decoder.rejectsWhatItCannotDecode")
@system unittest
{
    assert(!decodePng([1, 2, 3]).ok);
    const png = buildPng(1, 1, 6, 8, [0, 1, 2, 3, 4]);
    assert(!decodePng(png[0 .. $ - 20]).ok);
    // Interlaced: flip the IHDR interlace byte (offset 8+8+4+9).
    auto interlaced = png.dup;
    interlaced[28] = 1;
    assert(!decodePng(interlaced).ok);
}

@("terminal_view.png_decoder.rejectsBadCrc")
@system unittest
{
    const png = buildPng(1, 1, 6, 8, [0, 1, 2, 3, 4], null, null,
        PngChunkSpec("tEXt", [cast(ubyte) 'x'], true));
    assert(!decodePng(png).ok);
}

@("terminal_view.png_decoder.rejectsUnknownCriticalChunk")
@system unittest
{
    const png = buildPng(1, 1, 6, 8, [0, 1, 2, 3, 4], null, null,
        PngChunkSpec("ABCD", [1, 2]));
    assert(!decodePng(png).ok);
    // The same payload as an unknown ancillary chunk is tolerated.
    const ancillary = buildPng(1, 1, 6, 8, [0, 1, 2, 3, 4], null, null,
        PngChunkSpec("abCD", [1, 2]));
    assert(decodePng(ancillary).ok);
}

@("terminal_view.png_decoder.rejectsDuplicateIhdrOrMissingIend")
@system unittest
{
    const ubyte[] scan = [0, 1, 2, 3, 4];
    assert(!decodePng(buildPng(1, 1, 6, 8, scan, null, null,
        PngChunkSpec.init, true)).ok);
    assert(!decodePng(buildPng(1, 1, 6, 8, scan, null, null,
        PngChunkSpec.init, false, false)).ok);
}

@("terminal_view.png_decoder.invalidFilterByteRejected")
@system unittest
{
    assert(!decodePng(buildPng(1, 1, 6, 8, [5, 1, 2, 3, 4])).ok);
}

@("terminal_view.png_decoder.truncatedTrnsRejected")
@system unittest
{
    // Colour type 2 demands a 6-byte tRNS; 2 bytes is truncated.
    assert(!decodePng(buildPng(1, 1, 2, 8, [0, 1, 2, 3], null, [0, 1])).ok);
}

@("terminal_view.png_decoder.paletteTrnsAlpha")
@system unittest
{
    const img = decodePng(buildPng(2, 1, 3, 8, [0, 0, 1],
        [255, 0, 0, 0, 255, 0], [63]));
    assert(img.rgba == [255, 0, 0, 63, 0, 255, 0, 255]);
}

@("terminal_view.png_decoder.greyAlphaAndSubByte")
@system unittest
{
    const greyAlpha = decodePng(buildPng(1, 1, 4, 8, [0, 200, 128]));
    assert(greyAlpha.rgba == [200, 200, 200, 128]);

    // 1-bit grey: bits 1,0 scale to white, black.
    const subGrey = decodePng(buildPng(2, 1, 0, 1, [0, 0x80]));
    assert(subGrey.rgba == [255, 255, 255, 255, 0, 0, 0, 255]);

    // 2-bit palette: indices 0,1,2,3 packed into one byte.
    const subPal = decodePng(buildPng(4, 1, 3, 2, [0, 0x1B],
        [0, 0, 0, 85, 0, 0, 170, 0, 0, 255, 0, 0]));
    assert(subPal.rgba == [0, 0, 0, 255, 85, 0, 0, 255,
        170, 0, 0, 255, 255, 0, 0, 255]);
}

@("terminal_view.png_decoder.averageAndPaethFilters")
@system unittest
{
    // Average on a single row: left neighbour halves into the predictor.
    const avg = decodePng(buildPng(2, 1, 6, 8, [3, 100, 0, 0, 255, 60, 10, 10, 128]));
    assert(avg.rgba == [100, 0, 0, 255, 110, 10, 10, 255]);

    // Paeth on the second row of an RGB image.
    const paethImg = decodePng(buildPng(2, 2, 2, 8,
        [0, 100, 0, 0, 0, 100, 0, 4, 10, 10, 0, 10, 10, 0]));
    assert(paethImg.rgba == [100, 0, 0, 255, 0, 100, 0, 255,
        110, 10, 0, 255, 10, 110, 0, 255]);
}

@("terminal_view.png_decoder.splitIdat")
@system unittest
{
    const img = decodePng(buildPng(1, 1, 2, 8, [0, 1, 2, 3],
        null, null, PngChunkSpec.init, false, true, true));
    assert(img.rgba == [1, 2, 3, 255]);
}

@("terminal_view.png_decoder.decompressionBombRejected")
@system unittest
{
    // A 1×1 header whose IDAT inflates to 64 KiB of zeros.
    const png = buildPng(1, 1, 6, 8, new ubyte[64 * 1024]);
    assert(!decodePng(png).ok);
}

@("terminal_view.png_decoder.16BitRgb")
@system unittest
{
    const img = decodePng(buildPng(1, 1, 2, 16, [0, 0x12, 0x34, 0x80, 0x00, 0xFF, 0xFF]));
    assert(img.rgba == [0x12, 0x80, 0xFF, 255]);
}
