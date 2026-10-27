/**
The PNG decoder of bitmap strikes (FTR7) on hand-built PNGs: every filter
type over every decoded form, transparency, split data, and each refusal.
The expected pixels are the rows the fixture encoded, premultiplied by
hand.
*/
module sparkles.font.png_test;

import sparkles.font.errors : FontErrorKind, FontLimit;
import sparkles.font.fixtures;
import sparkles.font.png;

/// Decodes `png` with ample storage, or returns the error kind.
private struct Decoded
{
    bool ok;
    FontErrorKind kind;
    PngImage image;
    ubyte[] rgba;
}

private Decoded decode(const(ubyte)[] png) @safe pure nothrow
{
    auto rgba = new ubyte[1 << 16], inflated = new ubyte[1 << 16], zlib = new ubyte[pngZlibScratch];
    const r = decodePng(png, rgba, inflated, zlib);
    if (r.hasError)
        return Decoded(false, r.error.kind);
    return Decoded(true, FontErrorKind.init, r.value, rgba[0 .. r.value.imageNeeded]);
}

/// Rows of `width` RGBA pixels whose samples vary enough that every predictor matters.
private const(ubyte[])[] rgbaRows(uint width, uint height, bool opaque) @safe pure nothrow
{
    const(ubyte)[][] rows;
    foreach (y; 0 .. height)
    {
        ubyte[] row;
        foreach (x; 0 .. width)
            row ~= [cast(ubyte)(37 * x + 91 * y), cast(ubyte)(200 - 13 * x * y), cast(ubyte)(y * y * 29 + x),
                opaque ? 255 : cast(ubyte)(60 * x + 17 * y + 1)];
        rows ~= row;
    }
    return rows;
}

/// `rows` of straight RGBA, premultiplied by round(c · a / 255).
private ubyte[] premultiplied(const(ubyte[])[] rows) @safe pure nothrow
{
    ubyte[] r;
    foreach (row; rows)
        for (size_t i = 0; i < row.length; i += 4)
        {
            const a = row[i + 3];
            r ~= [cast(ubyte)((row[i] * a + 127) / 255), cast(ubyte)((row[i + 1] * a + 127) / 255),
                cast(ubyte)((row[i + 2] * a + 127) / 255), a];
        }
    return r;
}

@("png.filters.everyTypeRgba")
@safe pure nothrow
unittest
{
    // Five rows, one per filter type, then the same image under each single filter.
    const rows = rgbaRows(4, 5, false);
    auto d = decode(pngFile(PngSpec(4, 5, 8, 6, rows, [0, 1, 2, 3, 4])));
    assert(d.ok && d.image.width == 4 && d.image.height == 5);
    assert(d.rgba == premultiplied(rows));
    foreach (ubyte filter; 0 .. 5)
    {
        d = decode(pngFile(PngSpec(4, 5, 8, 6, rows, [filter, filter, filter, filter, filter])));
        assert(d.ok && d.rgba == premultiplied(rows));
    }
    // A hand-worked pixel: (37·1 + 91·1) = 128 red at alpha 60 + 17 + 1 = 78 is round(128 · 78 / 255) = 39.
    assert(d.rgba[4 * (4 + 1)] == 39 && d.rgba[4 * (4 + 1) + 3] == 78);
}

@("png.filters.everyTypeRgbAndSubByte")
@safe pure nothrow
unittest
{
    // RGB (3 bytes a pixel) and 4-bit indexed (filters see whole bytes, one byte a "pixel").
    const(ubyte)[][] rgb;
    foreach (y; 0 .. 5)
    {
        ubyte[] row;
        foreach (x; 0 .. 3) row ~= [cast(ubyte)(50 * x + y), cast(ubyte)(7 * y), cast(ubyte)(250 - 40 * x)];
        rgb ~= row;
    }
    auto d = decode(pngFile(PngSpec(3, 5, 8, 2, rgb, [4, 3, 2, 1, 0])));
    assert(d.ok);
    foreach (y; 0 .. 5)
        foreach (x; 0 .. 3)
            assert(d.rgba[4 * (3 * y + x) .. 4 * (3 * y + x) + 4] == rgb[y][3 * x .. 3 * x + 3] ~ [cast(ubyte) 255]);

    // A 16-entry palette of grey ramps; four pixels a row, two a byte.
    ubyte[] palette;
    foreach (i; 0 .. 16) palette ~= [cast(ubyte)(17 * i), cast(ubyte)(17 * i), cast(ubyte)(255 - 17 * i)];
    const(ubyte)[][] indexed = [[0x01, 0x23], [0x45, 0x67], [0x89, 0xAB], [0xCD, 0xEF], [0xF0, 0x0F]];
    d = decode(pngFile(PngSpec(4, 5, 4, 3, indexed, [1, 2, 3, 4, 0], palette)));
    assert(d.ok);
    foreach (y; 0 .. 5)
        foreach (x; 0 .. 4)
        {
            const index = (indexed[y][x / 2] >> (x % 2 ? 0 : 4)) & 0xF;
            assert(d.rgba[4 * (4 * y + x) .. 4 * (4 * y + x) + 4]
                == [cast(ubyte)(17 * index), cast(ubyte)(17 * index), cast(ubyte)(255 - 17 * index), 255]);
        }
}

@("png.forms.greyAlphaIndexedAndKeys")
@safe pure nothrow
unittest
{
    // Greyscale with a tRNS key: 128 is transparent.
    auto d = decode(pngFile(PngSpec(3, 1, 8, 0, [[10, 128, 255]], null, null, [0, 128])));
    assert(d.ok && d.rgba == [10, 10, 10, 255, 0, 0, 0, 0, 255, 255, 255, 255]);
    // Greyscale with alpha: 200 at alpha 51 is round(200 · 51 / 255) = 40.
    d = decode(pngFile(PngSpec(2, 1, 8, 4, [[200, 51, 9, 255]])));
    assert(d.ok && d.rgba == [40, 40, 40, 51, 9, 9, 9, 255]);
    // RGB with a key.
    d = decode(pngFile(PngSpec(2, 1, 8, 2, [[1, 2, 3, 4, 5, 6]], null, null, [0, 4, 0, 5, 0, 6])));
    assert(d.ok && d.rgba == [1, 2, 3, 255, 0, 0, 0, 0]);
    // Indexed at 1, 2 and 8 bits, with tRNS shorter than the palette.
    const ubyte[] palette = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255];
    d = decode(pngFile(PngSpec(8, 1, 1, 3, [[0b1010_0000]], null, palette, [0])));
    // 0b1010_0000: entries 1, 0, 1, then 0; entry 0 is transparent.
    assert(d.ok && d.rgba[0 .. 16] == [0, 255, 0, 255, 0, 0, 0, 0, 0, 255, 0, 255, 0, 0, 0, 0]);
    d = decode(pngFile(PngSpec(4, 1, 2, 3, [[0b00_01_10_11]], null, palette, [255, 102])));
    // Entry 1, green at alpha 102: round(255 · 102 / 255) = 102.
    assert(d.ok && d.rgba == [255, 0, 0, 255, 0, 102, 0, 102, 0, 0, 255, 255, 255, 255, 255, 255]);
    d = decode(pngFile(PngSpec(2, 1, 8, 3, [[3, 2]], null, palette)));
    assert(d.ok && d.rgba == [255, 255, 255, 255, 0, 0, 255, 255]);
}

@("png.data.splitAcrossChunks")
@safe pure nothrow
unittest
{
    const rows = rgbaRows(5, 4, true);
    const whole = decode(pngFile(PngSpec(5, 4, 8, 6, rows, [4, 4, 4, 4])));
    foreach (size; [1, 3, 7, 64])
    {
        auto spec = PngSpec(5, 4, 8, 6, rows, [4, 4, 4, 4]);
        spec.idatSize = size;
        const split = decode(pngFile(spec));
        assert(split.ok && split.rgba == whole.rgba);
    }
}

@("png.refusals")
@safe pure nothrow
unittest
{
    const rows = rgbaRows(2, 2, true);
    const good = pngFile(PngSpec(2, 2, 8, 6, rows));
    assert(decode(good).ok);

    // Forms outside FTR7: interlacing, 16 bits, sub-byte greyscale.
    auto spec = PngSpec(2, 2, 8, 6, rows);
    spec.interlace = 1;
    assert(decode(pngFile(spec)).kind == FontErrorKind.unsupportedVersion);
    assert(decode(pngFile(PngSpec(1, 1, 16, 0, [[0, 0]]))).kind == FontErrorKind.unsupportedVersion);
    assert(decode(pngFile(PngSpec(2, 1, 4, 0, [[0]]))).kind == FontErrorKind.unsupportedVersion);
    assert(decode(pngFile(PngSpec(1, 1, 8, 5, [[0]]))).kind == FontErrorKind.unsupportedVersion);

    // Not a PNG, or cut short.
    auto bad = good.dup;
    bad[1] = 'Q';
    assert(decode(bad).kind == FontErrorKind.badValue);
    assert(decode(good[0 .. 20]).kind == FontErrorKind.truncated);
    assert(decode(good[0 .. $ - 20]).kind == FontErrorKind.truncated);
    assert(decode(pngFile(PngSpec(0, 1, 8, 6, null))).kind == FontErrorKind.badValue);

    // A corrupt checksum, too few rows, an unknown filter.
    bad = good.dup;
    const adler = bad.length - 12 - 4 - 4; // the IDAT's last four body bytes
    bad[adler] ^= 0xFF;
    assert(decode(bad).kind == FontErrorKind.badValue);
    assert(decode(pngFile(PngSpec(2, 3, 8, 6, rows))).kind == FontErrorKind.badValue);
    assert(decode(pngFile(PngSpec(2, 2, 8, 6, rows, [0, 5]))).kind == FontErrorKind.badValue);

    // Indexed colour without a palette, or past it.
    assert(decode(pngFile(PngSpec(1, 1, 8, 3, [[0]]))).kind == FontErrorKind.badValue);
    assert(decode(pngFile(PngSpec(1, 1, 8, 3, [[1]], null, [1, 2, 3]))).kind == FontErrorKind.badValue);

    // IDAT chunks interrupted by another chunk.
    spec = PngSpec(2, 2, 8, 6, rows);
    spec.idatSize = 8;
    auto split = pngFile(spec);
    const second = 8 + 25 + 20; // signature, IHDR, then the first IDAT of 8 bytes
    split = split[0 .. second] ~ cast(ubyte[])[0, 0, 0, 0, 't', 'E', 'X', 't', 0, 0, 0, 0] ~ split[second .. $];
    assert(decode(split).kind == FontErrorKind.badValue);
}

@("png.storage.callerStorage")
@safe pure nothrow
unittest
{
    const png = pngFile(PngSpec(3, 2, 8, 6, rgbaRows(3, 2, true)));
    const header = pngHeader(png);
    assert(header.hasValue && header.value.imageNeeded == 24 && header.value.inflatedNeeded == 2 * (1 + 12));
    auto rgba = new ubyte[24], inflated = new ubyte[26], zlib = new ubyte[pngZlibScratch];
    assert(decodePng(png, rgba, inflated, zlib).hasValue);
    foreach (short_; 0 .. 3)
    {
        const r = decodePng(png, short_ == 0 ? rgba[0 .. 23] : rgba, short_ == 1 ? inflated[0 .. 25] : inflated,
            short_ == 2 ? zlib[0 .. $ - 1] : zlib);
        assert(r.hasError && r.error.kind == FontErrorKind.limitExceeded && r.error.limit == FontLimit.callerStorage);
        assert(r.error.needed == [24UL, 26, pngZlibScratch][short_]);
    }
}
