#!/usr/bin/env dub
/+ dub.sdl:
    name "images_mir_slice_planar"
    dependency "sparkles:base" path="../../../../.."
    dependency "mir-algorithm" version="==3.22.4"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Planar YUV 4:2:0 as three mir `Slice`s of different extents over one
 * allocation, each with a padded row stride, and a lazy RGB view computed from
 * them; then a packed 3-byte RGB image whose padded row stride is not a whole
 * number of pixels, which a `Slice` of a pixel struct cannot express.
 *
 * The frame is 9 x 5, so the chroma planes are ceil(9/2) x ceil(5/2) = 5 x 3:
 * odd extents are where 4:2:0 code usually goes wrong.
 *
 * Backs ./slice-experiment.md (section "Planar YUV and padded strides").
 *
 * Run with: `dub run --single slice-planar.d`
 */
module images_mir_slice_planar;

import std.stdio : writefln;

import mir.ndslice.slice : Canonical, Slice, sliced, Universal;
import mir.ndslice.topology : flattened, ndiota, vmap;

import sparkles.base.buffer : HeapBuffer, Storage;

enum size_t width = 9, height = 5;
enum size_t chromaWidth = (width + 1) / 2, chromaHeight = (height + 1) / 2;

/// Row strides in bytes, padded as a decoder or a GPU would (16 and 8).
enum size_t lumaStride = 16, chromaStride = 8;

enum size_t lumaBytes = lumaStride * height;
enum size_t chromaBytes = chromaStride * chromaHeight;

struct Rgb8
{
    ubyte r, g, b;
}

static assert(Rgb8.sizeof == 3);

ubyte clamp8(int v) @safe pure nothrow @nogc => cast(ubyte) (v < 0 ? 0 : v > 255 ? 255 : v);

/// BT.601 full-range YCbCr to RGB, 8.8 fixed point.
Rgb8 yuvToRgb(ubyte y, ubyte u, ubyte v) @safe pure nothrow @nogc
{
    const int c = y, d = u - 128, e = v - 128;
    return Rgb8(clamp8(c + ((359 * e + 128) >> 8)), clamp8(c - ((88 * d + 183 * e + 128) >> 8)),
        clamp8(c + ((454 * d + 128) >> 8)));
}

/// One plane: a contiguous `rows x stride` matrix over the bytes, cropped to
/// `rows x cols`. The crop of the last dimension makes it Canonical: the row
/// stride is stored, the column stride is 1.
Slice!(ubyte*, 2, Canonical) plane(return scope ubyte[] bytes, size_t rows, size_t cols, size_t stride)
    @safe pure nothrow @nogc
    => bytes.sliced(rows, stride)[0 .. $, 0 .. cols];

uint fnv1a(S)(S s)
{
    uint h = 2_166_136_261;
    foreach (b; s.flattened)
    {
        h ^= b;
        h *= 16_777_619;
    }
    return h;
}

/// The three planes as one callable: index (y, x) to RGB, chroma at half
/// resolution. A struct, not a lambda: see `convert`.
struct Yuv420
{
    Slice!(ubyte*, 2, Canonical) yp, up, vp;

    Rgb8 opCall(size_t[2] i) const @safe pure nothrow @nogc
        => yuvToRgb(yp[i[0], i[1]], up[i[0] / 2, i[1] / 2], vp[i[0] / 2, i[1] / 2]);
}

/// Converts the frame into `dst`: a lazy `ndiota` view over the luma extent,
/// mapped through `Yuv420`; assigning it runs it. `ndiota(...).map!(i => ...)`
/// with a lambda reading the planes is rejected under `@nogc` ("allocates
/// closure"), so the planes travel in the functor `vmap` takes.
void convert(Slice!(ubyte*, 2, Canonical) yp, Slice!(ubyte*, 2, Canonical) up, Slice!(ubyte*, 2, Canonical) vp,
    Slice!(Rgb8*, 2) dst) @safe pure nothrow @nogc
{
    // A struct initialiser, not `Yuv420(yp, up, vp)`: with an `opCall`
    // member DMD 2.112 resolves that call syntax to `opCall` (LDC 1.43 does not).
    Yuv420 f = {yp: yp, up: up, vp: vp};
    dst[] = ndiota(yp.length!0, yp.length!1).vmap(f);
}

void main() @safe
{
    // One owner for the whole frame: Y, then U, then V, each plane padded.
    // Heap-only and move-only (`UniqueBuffer!(ubyte, 0)` is rejected: an
    // inline policy needs N > 0).
    HeapBuffer!(ubyte, Storage.unique) frame;
    frame.length = lumaBytes + 2 * chromaBytes;
    ubyte[] bytes = frame[];
    bytes[] = 0xEE; // padding is visible if anything reads it

    auto yp = plane(bytes[0 .. lumaBytes], height, width, lumaStride);
    auto up = plane(bytes[lumaBytes .. lumaBytes + chromaBytes], chromaHeight, chromaWidth, chromaStride);
    auto vp = plane(bytes[lumaBytes + chromaBytes .. $], chromaHeight, chromaWidth, chromaStride);

    foreach (y; 0 .. height)
        foreach (x; 0 .. width)
            yp[y, x] = cast(ubyte) (16 + y * 40 + x * 20);
    foreach (y; 0 .. chromaHeight)
        foreach (x; 0 .. chromaWidth)
        {
            up[y, x] = cast(ubyte) (64 + x * 32);
            vp[y, x] = cast(ubyte) (192 - y * 48);
        }

    writefln("Y lengths %s strides %s  U lengths %s strides %s  V lengths %s strides %s", yp.shape, yp.strides,
        up.shape, up.strides, vp.shape, vp.strides);
    writefln("fnv1a Y %08x U %08x V %08x  (padding not visited)", fnv1a(yp), fnv1a(up), fnv1a(vp));

    auto rgb = new Rgb8[](width * height).sliced(height, width);
    convert(yp, up, vp, rgb);
    writefln("rgb[0, 0] %s  rgb[4, 8] %s", rgb[0, 0], rgb[4, 8]);
    writefln("fnv1a rgb %08x", fnv1a((cast(ubyte[]) rgb.field).sliced(height, width, 3)));

    // A packed RGB image, 9 pixels = 27 bytes a row, padded to a 32-byte stride.
    enum size_t rgbStride = 32;
    auto packed = new ubyte[](rgbStride * height);
    packed[] = 0xEE;

    // As bytes it is a Canonical 2-D slice (rows x 27).
    auto rows = packed.sliced(height, rgbStride)[0 .. $, 0 .. width * 3];

    // As pixels it is not a Slice at all: mir strides count elements, and a
    // 32-byte stride is 10 2/3 `Rgb8`s.
    writefln("rgbStride %% Rgb8.sizeof = %s, so no Slice!(Rgb8*, 2) has this stride", rgbStride % Rgb8.sizeof);

    // As a 3-D byte slice it is Universal, built from the public fields. That
    // struct literal is `@system` here only because of the pointer; mir does
    // not check it against the array's length (see the experiment write-up).
    auto px = () @trusted {
        return Slice!(ubyte*, 3, Universal)([height, width, 3], [cast(ptrdiff_t) rgbStride, 3, 1], packed.ptr);
    }();
    foreach (y; 0 .. height)
        foreach (x; 0 .. width)
        {
            const p = rgb[y, x];
            px[y, x, 0] = p.r;
            px[y, x, 1] = p.g;
            px[y, x, 2] = p.b;
        }
    writefln("packed 3-D lengths %s strides %s  px[4, 8] %s", px.shape, px.strides, px[4, 8]);
    writefln("fnv1a packed %08x == fnv1a rgb: %s  row bytes fnv1a %08x", fnv1a(px),
        fnv1a(px) == fnv1a((cast(ubyte[]) rgb.field).sliced(height, width, 3)), fnv1a(rows));
    writefln("padding byte packed[27] = 0x%02X (untouched)", packed[27]);
}
