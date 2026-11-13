#!/usr/bin/env dub
/+ dub.sdl:
    name "images_mir_slice_views"
    dependency "sparkles:base" path="../../../../.."
    dependency "mir-algorithm" version="==3.22.4"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * mir `Slice` as an image view: one interleaved RGBA8 buffer seen as a 2-D
 * slice of a pixel struct, as a 3-D slice of bytes, through a crop and through
 * a transpose, none of which copies a pixel.
 *
 * The storage is a `sparkles.base.buffer.UniqueBuffer`, so the experiment also
 * shows how a `Slice` borrows memory a Sparkles owner holds, and what dip1000
 * says about that borrow.
 *
 * Backs ./slice-experiment.md (sections "Views over one buffer" and
 * "Borrowing a UniqueBuffer").
 *
 * Run with: `dub run --single slice-views.d`
 */
module images_mir_slice_views;

import std.stdio : writefln, writeln;

import mir.ndslice.dynamic : transposed;
import mir.ndslice.slice : Canonical, Contiguous, Slice, SliceKind, sliced, Universal;
import mir.ndslice.topology : flattened, member;

import sparkles.base.buffer : UniqueBuffer;

/// The pixel: four 8-bit samples, straight alpha, in memory order.
struct Rgba8
{
    ubyte r, g, b, a;
}

static assert(Rgba8.sizeof == 4 && Rgba8.alignof == 1);

enum size_t width = 6;
enum size_t height = 4;

/// A deterministic test pattern: every sample depends on (x, y).
Rgba8 pattern(size_t y, size_t x) @safe pure nothrow @nogc
    => Rgba8(cast(ubyte) (x * 40), cast(ubyte) (y * 60), cast(ubyte) (x + y * width), cast(ubyte) (255 - x * 20));

/// FNV-1a over every sample a byte slice of any dimension and kind visits, in
/// row-major order. Generic over the slice, so attributes are inferred.
uint fnv1a(S)(S bytes)
{
    uint h = 2_166_136_261;
    foreach (b; bytes.flattened)
    {
        h ^= b;
        h *= 16_777_619;
    }
    return h;
}

/// Fills an RGBA image view in place: the function sees only a `Slice`, never
/// the owner. `@safe pure nothrow @nogc` holds for any contiguous view.
void fill(Slice!(Rgba8*, 2) img) @safe pure nothrow @nogc
{
    foreach (y; 0 .. img.length!0)
        foreach (x; 0 .. img.length!1)
            img[y, x] = pattern(y, x);
}

/// Sum of the red channel through a `member` projection, for a view of any
/// kind: the same code runs on the full image, a crop and a transpose.
size_t redSum(Iterator, SliceKind kind)(Slice!(Iterator, 2, kind) img)
{
    size_t s;
    foreach (v; img.member!"r".flattened)
        s += v;
    return s;
}

void main() @safe
{
    // The owner: a move-only Sparkles buffer, inline up to 64 bytes, on the
    // heap above (96 bytes here).
    UniqueBuffer!(ubyte, 64) storage;
    storage.length = width * height * Rgba8.sizeof;

    // Borrow its bytes. `opSlice` is `return scope`, so `bytes` cannot
    // outlive `storage` under dip1000.
    ubyte[] bytes = storage[];

    // 1. The same memory as a 2-D slice of pixels and as a 3-D slice of bytes.
    //    `cast(Rgba8[])` of a `ubyte[]` is `@safe`: neither type has
    //    indirections, and the length is checked at run time.
    auto img = (cast(Rgba8[]) bytes).sliced(height, width);
    auto img3 = bytes.sliced(height, width, 4);
    static assert(is(typeof(img) == Slice!(Rgba8*, 2, Contiguous)));
    static assert(is(typeof(img3) == Slice!(ubyte*, 3, Contiguous)));
    fill(img);

    writefln("img   lengths %s, img3 lengths %s", img.shape, img3.shape);
    writefln("img[2, 3]  = %s", img[2, 3]);
    writefln("img3[2, 3] = %s", img3[2, 3]);
    writefln("fnv1a(img3) = %08x", fnv1a(img3));

    // 2. A crop: rows 1..3, columns 2..5. Slicing the last dimension too makes
    //    the view Canonical (a row stride, unit column stride).
    auto crop = img[1 .. 3, 2 .. 5];
    static assert(is(typeof(crop) == Slice!(Rgba8*, 2, Canonical)));
    writefln("crop  lengths %s strides %s", crop.shape, crop.strides);

    // 3. A transpose: Universal, every stride stored, still no copy.
    auto tr = img.transposed;
    static assert(is(typeof(tr) == Slice!(Rgba8*, 2, Universal)));
    writefln("tr    lengths %s strides %s", tr.shape, tr.strides);
    writefln("tr[3, 2] == img[2, 3]: %s", tr[3, 2] == img[2, 3]);

    // One generic function over all three kinds.
    writefln("redSum img %s crop %s tr %s", redSum(img), redSum(crop), redSum(tr));

    // 4. Writing through the crop changes the owner's bytes: a view, not a copy.
    crop[] = Rgba8(1, 2, 3, 4);
    writefln("after crop[] = (1,2,3,4): bytes[%s .. %s] = %s",
        (1 * width + 2) * 4, (1 * width + 2) * 4 + 4,
        bytes[(1 * width + 2) * 4 .. (1 * width + 2) * 4 + 4]);
    writefln("fnv1a(img3) = %08x", fnv1a(img3));

    // 5. A 3-D byte view of the crop: the cropped pixel view cast to bytes is
    //    not expressible as a safe array cast (the crop is not one array), so
    //    the byte view comes from slicing the 3-D view the same way.
    auto crop3 = img3[1 .. 3, 2 .. 5];
    static assert(is(typeof(crop3) == Slice!(ubyte*, 3, Canonical)));
    writefln("crop3 lengths %s strides %s fnv1a %08x", crop3.shape, crop3.strides, fnv1a(crop3));

    // 6. One channel as its own 2-D view (stride 4 bytes), via the 3-D slice.
    auto alpha = img3[0 .. $, 0 .. $, 3];
    static assert(is(typeof(alpha) == Slice!(ubyte*, 2, Universal)));
    writefln("alpha lengths %s strides %s row 0 %s", alpha.shape, alpha.strides, alpha[0]);
}
