/**
The PNG decoding of bitmap colour strikes (`docs/specs/font/SPEC.md` FTR7,
FTX4): `sparkles:image`'s decoder, with its refusals as `FontError`s.

`pngHeader` reads a PNG's `IHDR` and says what decoding it needs;
`decodePng` decodes it into a caller-owned premultiplied RGBA image, with
nothing allocated. Every form the PNG format defines is decoded; see
`sparkles.image.png` for what is refused and why.

Errors carry offsets from the start of the PNG and no table; the strike
reader rebases them onto the table that holds the PNG.
*/
module sparkles.font.png;

import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontResult, fontErr,
    fontOk, Tag;

import image = sparkles.image.png;

public import sparkles.image.png : PngImage, pngZlibScratch;

@safe pure nothrow @nogc:

/**
The form of `png` and the storage `decodePng` needs for it, from its
signature and `IHDR`. A missing signature or `IHDR`, or a zero dimension,
is `badValue`; a short header is `truncated`; a form the format does not
define is `unsupportedVersion`; an image too large to decode is
`arithmeticExhausted`. O(1).
*/
FontResult!PngImage pngHeader(scope const(ubyte)[] png)
{
    const r = image.pngHeader(png);
    return r.hasError ? fontErr!PngImage(fontError(r.error)) : fontOk!PngImage(r.value);
}

/**
Decodes `png` into `rgba`: `width · height` pixels of premultiplied RGBA,
rows top to bottom with no padding, alpha associated by
`round(c · a / 255)`. `inflated` holds the filtered scanlines and
`zlibScratch` the inflate state: each must be at least the length
`pngHeader` and `pngZlibScratch` state, and a shorter one is
`limitExceeded` naming `callerStorage`.

The errors of `pngHeader` apply; a file that breaks the format is
`badValue`, and one ending before its end is `truncated`.
*/
FontResult!PngImage decodePng(scope const(ubyte)[] png, scope ubyte[] rgba, scope ubyte[] inflated,
    scope ubyte[] zlibScratch)
{
    const r = image.decodePng(png, rgba, inflated, zlibScratch, image.Alpha.premultiplied);
    return r.hasError ? fontErr!PngImage(fontError(r.error)) : fontOk!PngImage(r.value);
}

private FontError fontError(in image.PngError e)
{
    final switch (e.kind)
    {
        case image.PngErrorKind.truncated:
            return FontError(FontErrorKind.truncated, Tag.init, e.offset);
        case image.PngErrorKind.malformed:
            return FontError(FontErrorKind.badValue, Tag.init, e.offset);
        case image.PngErrorKind.unsupported:
            return FontError(FontErrorKind.unsupportedVersion, Tag.init, e.offset);
        case image.PngErrorKind.tooLarge:
            return FontError(FontErrorKind.arithmeticExhausted, Tag.init, e.offset);
        case image.PngErrorKind.callerStorage:
            return callerStorageError(e.needed);
    }
}
