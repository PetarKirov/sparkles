# sparkles:image

Image file codecs. Today that is PNG: one decoder, shared by everything in
the project that reads a PNG (a terminal's kitty graphics, an emoji font's
colour strikes), and an encoder for screenshots and test captures.

```d
import sparkles.image.png;

ubyte[] decodeOrNull(in ubyte[] file) @safe pure nothrow
{
    // The allocating convenience: pixels as 8-bit RGBA, rows top to bottom.
    const r = decodePngAlloc(file);
    return r.hasValue ? r.value.rgba.dup : null;
}
```

## Decoding into your own storage

`decodePng` allocates nothing. `pngHeader` reads a file's signature and
`IHDR` and reports what decoding needs: `imageNeeded` bytes for the pixels
and `inflatedNeeded` for the filtered scanlines. zlib's state takes
`pngZlibScratch` bytes more. The caller owns all three arrays, so a decode
can run in `@nogc` code, from a fixed arena, or straight into a buffer
another library hands over:

```d
import sparkles.image.png;

bool decodeInto(in ubyte[] file, ubyte[] pixels, ubyte[] scanlines,
    ubyte[] zlibScratch) @safe pure nothrow @nogc
{
    const header = pngHeader(file);
    if (header.hasError || pixels.length < header.value.imageNeeded)
        return false;
    return decodePng(file, pixels, scanlines, zlibScratch, Alpha.premultiplied).hasValue;
}
```

`Alpha.straight` keeps colour as the file stores it; `Alpha.premultiplied`
multiplies it by alpha, `round(c · a / 255)`, as a compositor wants it.

## What it decodes

Every colour type at every bit depth the format allows (1 to 16 bits),
`tRNS` transparency, all five scanline filters, and Adam7 interlacing. It
decodes as stb_image does: chunk checksums are not checked (the zlib
stream's Adler-32 is), 16-bit samples keep their high byte, and sub-byte
greyscale scales to the full range. `sparkles.ui_raylib.png_oracle` holds
the two to the same bytes over PngSuite and libpng's test images.

A refusal is a `PngError`: its kind (`truncated`, `malformed`,
`unsupported`, `tooLarge`, `callerStorage`) and the offset in the file it
concerns. Decoding is bounded by the image the header declares: the
inflated stream must be exactly the scanlines' length, so a small file
cannot expand past its storage, and an image over `maxPngPixels`
(2²⁶ pixels) is refused.

## Encoding

`encodePng(rgba, width, height)` writes 8-bit RGBA as the smallest valid
file: one `IDAT` of unfiltered rows. Its users read the result, so it does
not try to compress well.
