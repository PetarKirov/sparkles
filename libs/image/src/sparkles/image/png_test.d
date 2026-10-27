/**
The PNG codec on files built in memory: every colour type and depth,
transparency, every filter, Adam7, the chunk rules, both alpha forms,
caller storage, and hostile input. The differential test against
stb_image over PngSuite is `sparkles.ui_raylib.png_oracle`.
*/
module sparkles.image.png_test;

import sparkles.image.png;

import sparkles.test_runner.attributes;

private:

struct ChunkSpec
{
    string type;
    const(ubyte)[] payload;
    bool badCrc;
}

immutable ubyte[8] signature = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'];

ubyte[4] bigEndian(uint v) @safe pure nothrow @nogc
    => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

void addChunk(ref ubyte[] png, string type, in ubyte[] payload, bool badCrc = false) @safe
{
    import std.digest.crc : CRC32;

    png ~= bigEndian(cast(uint) payload.length);
    const start = png.length;
    png ~= cast(const(ubyte)[]) type;
    png ~= payload;
    CRC32 crc;
    crc.put(png[start .. $]);
    const sum = crc.finish();
    png ~= [sum[3], sum[2], sum[1], sum[0]];
    if (badCrc)
        png[$ - 1] ^= 0xFF;
}

// `scanlines` already carry their filter bytes; `extra` goes after
// PLTE/tRNS, before IDAT.
ubyte[] buildPng(uint w, uint h, ubyte colourType, ubyte bitDepth, in ubyte[] scanlines,
    in ubyte[] plte = null, in ubyte[] trns = null, ChunkSpec extra = ChunkSpec.init,
    bool duplicateIhdr = false, bool includeIend = true, bool splitIdat = false,
    bool interlaced = false) @safe
{
    import std.zlib : compress;

    ubyte[] png = signature.dup;
    ubyte[13] ihdr;
    ihdr[0 .. 4] = bigEndian(w);
    ihdr[4 .. 8] = bigEndian(h);
    ihdr[8] = bitDepth;
    ihdr[9] = colourType;
    ihdr[12] = interlaced;
    addChunk(png, "IHDR", ihdr[]);
    if (duplicateIhdr)
        addChunk(png, "IHDR", ihdr[]);
    if (plte.length)
        addChunk(png, "PLTE", plte);
    if (trns.length)
        addChunk(png, "tRNS", trns);
    if (extra.type.length)
        addChunk(png, extra.type, extra.payload, extra.badCrc);
    const idat = (() @trusted => cast(const(ubyte)[]) compress(scanlines))();
    if (splitIdat && idat.length > 1)
    {
        addChunk(png, "IDAT", idat[0 .. $ / 2]);
        addChunk(png, "IDAT", idat[$ / 2 .. $]);
    }
    else
        addChunk(png, "IDAT", idat);
    if (includeIend)
        addChunk(png, "IEND", null);
    return png;
}

// The decoded pixels, or none.
ubyte[] decoded(in ubyte[] png, Alpha alpha = Alpha.straight) @safe pure nothrow
{
    const r = decodePngAlloc(png, alpha);
    return r.hasValue ? r.value.rgba.dup : null;
}

PngErrorKind refusal(in ubyte[] png) @safe pure nothrow
{
    const r = decodePngAlloc(png);
    assert(r.hasError, "decoded a file it should refuse");
    return r.error.kind;
}

@("image.png.encodeThenDecodeIsTheIdentity")
@safe unittest
{
    const ubyte[] rgba = [1, 2, 3, 4, 250, 240, 230, 220, 9, 8, 7, 0, 0, 0, 0, 255];
    const r = decodePngAlloc(encodePng(rgba, 2, 2));
    assert(r.hasValue && r.value.rgba == rgba && r.value.width == 2 && r.value.height == 2);
}

@("image.png.colourTypesAndDepths")
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

@("image.png.transparencyKeysAndPaletteAlpha")
@safe unittest
{
    assert(decoded(buildPng(2, 1, 3, 8, [0, 0, 1], [255, 0, 0, 0, 255, 0], [63]))
        == [255, 0, 0, 63, 0, 255, 0, 255]);
    assert(decoded(buildPng(2, 1, 0, 8, [0, 7, 8], null, [0, 7]))
        == [7, 7, 7, 0, 8, 8, 8, 255], "a grey key at the native depth");
    assert(decoded(buildPng(2, 1, 0, 16, [0, 1, 7, 0, 7], null, [1, 7]))
        == [1, 1, 1, 0, 0, 0, 0, 255], "a 16-bit key compares all 16 bits");
    assert(refusal(buildPng(1, 1, 2, 8, [0, 1, 2, 3], null, [0, 1])) == PngErrorKind.malformed,
        "an RGB key is six bytes");
    assert(refusal(buildPng(1, 1, 6, 8, [0, 1, 2, 3, 4], null, [0, 1])) == PngErrorKind.malformed,
        "an image with alpha has no key");
}

@("image.png.premultipliedAlpha")
@safe unittest
{
    // round(200 · 51 / 255) = 40; round(128 · 78 / 255) = 39.
    assert(decoded(buildPng(2, 1, 4, 8, [0, 200, 51, 9, 255]), Alpha.premultiplied)
        == [40, 40, 40, 51, 9, 9, 9, 255]);
    assert(decoded(buildPng(1, 1, 6, 8, [0, 128, 255, 0, 78]), Alpha.premultiplied) == [39, 78, 0, 78]);
    assert(decoded(buildPng(2, 1, 3, 8, [0, 0, 1], [255, 0, 0, 0, 255, 0], [0]), Alpha.premultiplied)
        == [0, 0, 0, 0, 0, 255, 0, 255], "a transparent palette entry");
}

@("image.png.everyFilter")
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
    assert(refusal(buildPng(1, 1, 6, 8, [5, 1, 2, 3, 4])) == PngErrorKind.malformed, "no filter 5");
}

@("image.png.adam7PlacesEachPass")
@safe unittest
{
    // A 2×2 grey image has three non-empty passes: 1 holds (0, 0), 6 holds
    // (1, 0), 7 holds the second row.
    assert(decoded(buildPng(2, 2, 0, 8, [0, 10, 0, 20, 0, 30, 40], interlaced: true))
        == [10, 10, 10, 255, 20, 20, 20, 255, 30, 30, 30, 255, 40, 40, 40, 255]);
    // Each pass's first row has no row above it: an up filter there adds nothing.
    assert(decoded(buildPng(2, 2, 0, 8, [2, 10, 2, 20, 2, 30, 40], interlaced: true))
        == [10, 10, 10, 255, 20, 20, 20, 255, 30, 30, 30, 255, 40, 40, 40, 255]);
}

@("image.png.chunkRules")
@safe unittest
{
    const ubyte[] scan = [0, 1, 2, 3, 4];
    assert(decoded(buildPng(1, 1, 6, 8, scan, null, null, ChunkSpec("tEXt", [1], true))).length,
        "a bad checksum is not checked, as stb_image does not");
    assert(refusal(buildPng(1, 1, 6, 8, scan, null, null, ChunkSpec("ABCD", [1, 2])))
        == PngErrorKind.malformed, "an unknown critical chunk");
    assert(decoded(buildPng(1, 1, 6, 8, scan, null, null, ChunkSpec("abCD", [1, 2]))).length,
        "an unknown ancillary one is skipped");
    assert(refusal(buildPng(1, 1, 6, 8, scan, null, null, ChunkSpec.init, true)) == PngErrorKind.malformed,
        "two headers");
    assert(refusal(buildPng(1, 1, 6, 8, scan, null, null, ChunkSpec.init, false, false))
        == PngErrorKind.truncated, "no end");
    assert(decoded(buildPng(1, 1, 2, 8, [0, 1, 2, 3], null, null, ChunkSpec.init, false, true, true))
        == [1, 2, 3, 255], "data split over two IDAT chunks");
    assert(refusal(buildPng(1, 1, 3, 8, [0, 0])) == PngErrorKind.malformed, "indexed without a palette");
    assert(refusal(buildPng(1, 1, 3, 8, [0, 1], [1, 2, 3])) == PngErrorKind.malformed, "an index past it");
    assert(decoded(buildPng(1, 1, 3, 1, [0, 0], [1, 2, 3, 4, 5, 6, 7, 8, 9])) == [1, 2, 3, 255],
        "more palette entries than the depth can index, as stb_image and libpng accept");
}

@("image.png.headerRefusals")
@safe unittest
{
    assert(refusal([1, 2, 3]) == PngErrorKind.truncated);
    auto png = buildPng(1, 1, 6, 8, [0, 1, 2, 3, 4]);
    png[1] = 'Q';
    assert(refusal(png) == PngErrorKind.malformed, "not a PNG");
    assert(refusal(buildPng(0, 1, 6, 8, [0])) == PngErrorKind.malformed, "a zero width");
    assert(refusal(buildPng(1, 1, 5, 8, [0, 0])) == PngErrorKind.unsupported, "colour type 5");
    assert(refusal(buildPng(1, 1, 6, 4, [0, 0])) == PngErrorKind.unsupported, "4-bit RGBA");
    assert(refusal(buildPng(1 << 13, (1 << 13) + 1, 0, 8, [0])) == PngErrorKind.tooLarge, "over 2^26 pixels");
    const header = pngHeader(buildPng(1 << 13, (1 << 13) + 1, 0, 8, [0]));
    assert(header.hasError && header.error.offset == 16);
}

@("image.png.malformedAndHostileInputs")
@safe unittest
{
    const png = buildPng(1, 1, 6, 8, [0, 1, 2, 3, 4]);
    assert(refusal(png[0 .. $ - 20]) == PngErrorKind.truncated, "cut short");
    assert(refusal(png[0 .. 31]) == PngErrorKind.truncated, "cut inside the header's checksum");
    assert(refusal(buildPng(1, 1, 6, 8, new ubyte[64 * 1024])) == PngErrorKind.malformed,
        "inflates beyond what the header declares");
    assert(refusal(buildPng(1, 2, 6, 8, [0, 1, 2, 3, 4])) == PngErrorKind.malformed,
        "inflates short of what the header declares");
    auto bad = png.dup;
    bad[$ - 12 - 4 - 1] ^= 0xFF; // the IDAT's last body byte: its Adler-32
    assert(refusal(bad) == PngErrorKind.malformed, "a corrupt checksum");
}

@("image.png.callerStorageAndNoAllocation")
@safe pure nothrow @nogc unittest
{
    static immutable ubyte[] png = [
        0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n',
        0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1F, 0x15, 0xC4, 0x89,
        0, 0, 0, 13, 'I', 'D', 'A', 'T', 0x78, 0x9C, 0x63, 0x60, 0x60, 0x64, 0x62, 0x06, 0x00, 0x00, 0x0F,
        0x00, 0x07, 0, 0, 0, 0,
        0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xAE, 0x42, 0x60, 0x82,
    ];
    ubyte[4] rgba;
    ubyte[5] inflated;
    ubyte[pngZlibScratch] zlib;
    const header = pngHeader(png);
    assert(header.hasValue && header.value.imageNeeded == 4 && header.value.inflatedNeeded == 5);
    const r = decodePng(png, rgba[], inflated[], zlib[]);
    assert(r.hasValue && rgba == [0, 1, 2, 3]);
    foreach (short_; 0 .. 3)
    {
        const e = decodePng(png, short_ == 0 ? rgba[0 .. 3] : rgba[], short_ == 1 ? inflated[0 .. 4] : inflated[],
            short_ == 2 ? zlib[0 .. $ - 1] : zlib[]);
        assert(e.hasError && e.error.kind == PngErrorKind.callerStorage);
        static immutable ulong[3] needed = [4, 5, pngZlibScratch];
        assert(e.error.needed == needed[short_]);
    }
}
