/**
A PNG file of 8-bit RGBA pixels: what the native arm writes a screenshot as.

The smallest encoder that is still a valid PNG — one `IDAT` of unfiltered
rows, deflated by Phobos' zlib — because a capture is read by a test or a
person, never streamed, and its size does not matter.
*/
module sparkles.ui_app.png;

import std.digest.crc : CRC32;
import std.zlib : compress;

/// The PNG file of `width`×`height` RGBA pixels in `rgba`, rows top to bottom.
ubyte[] encodePng(scope const(ubyte)[] rgba, uint width, uint height) @safe
in (rgba.length == size_t(width) * height * 4, "the pixels must fill the image exactly")
{
    // Every row starts with its filter type: 0, none.
    auto raw = new ubyte[(size_t(width) * 4 + 1) * height];
    foreach (y; 0 .. height)
    {
        const row = size_t(y) * (width * 4 + 1);
        raw[row] = 0;
        raw[row + 1 .. row + 1 + width * 4] = rgba[size_t(y) * width * 4 .. size_t(y + 1) * width * 4];
    }

    ubyte[] png = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'];
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

// A chunk: its length, its type, its data, and the CRC-32 of type and data.
private void chunk(ref ubyte[] png, string type, scope const(ubyte)[] data) @safe
{
    png ~= bigEndian(cast(uint) data.length);
    const start = png.length;
    png ~= cast(const(ubyte)[]) type;
    png ~= data;
    CRC32 crc;
    crc.put(png[start .. $]);
    const sum = crc.finish(); // least significant byte first
    png ~= [sum[3], sum[2], sum[1], sum[0]];
}

private ubyte[4] bigEndian(uint v) @safe pure nothrow @nogc
    => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

@("ui_app.png.chunksAndChecksums")
@safe unittest
{
    const png = encodePng([255, 0, 0, 255, 0, 255, 0, 128], 2, 1);
    assert(png[0 .. 8] == [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n']);
    // IHDR: length 13, then the type, the size, and its known checksum.
    assert(png[8 .. 16] == [0, 0, 0, 13, 'I', 'H', 'D', 'R']);
    assert(png[16 .. 24] == [0, 0, 0, 2, 0, 0, 0, 1]);
    assert(png[24 .. 29] == [8, 6, 0, 0, 0]);
    // Every PNG ends with the same empty IEND and its fixed checksum.
    assert(png[$ - 12 .. $] == [0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xAE, 0x42, 0x60, 0x82]);
    // The IDAT inflates back to the filtered rows.
    import std.zlib : uncompress;

    const idatLength = (png[33] << 24) | (png[34] << 16) | (png[35] << 8) | png[36];
    assert(png[37 .. 41] == "IDAT");
    const rows = (() @trusted => cast(const(ubyte)[]) uncompress(png[41 .. 41 + idatLength]))();
    assert(rows == [0, 255, 0, 0, 255, 0, 255, 0, 128]);
}
