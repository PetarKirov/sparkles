#!/usr/bin/env dub
/+ dub.sdl:
    name "images_mir_slice_algorithms"
    dependency "sparkles:math" path="../../../../.."
    dependency "mir-algorithm" version="==3.22.4"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Two image algorithms over mir `Slice` views: a per-pixel map (straight to
 * premultiplied alpha) and a 3x3 box blur over overlapping `windows`, each
 * written once against a pixel struct and once against `sparkles.math`'s
 * `Vector` as the pixel type, plus a hand-written loop blur over one 8-bit
 * plane for the generated-code comparison.
 *
 * Every kernel is a non-template `@safe pure nothrow @nogc` function, so the
 * compiler checks those attributes rather than inferring them.
 *
 * Backs ./slice-experiment.md (sections "Per-pixel map", "Box blur over
 * windows", "sparkles.math Vector as the pixel" and "Generated code").
 *
 * Run with: `dub run --single slice-algorithms.d`
 */
module images_mir_slice_algorithms;

import std.stdio : writefln;

import mir.ndslice.slice : Slice, sliced;
import mir.ndslice.topology : flattened, map, windows;

import sparkles.math : Vector;

struct Rgba8
{
    ubyte r, g, b, a;
}

/// `sparkles.math`'s vector as the pixel: four packed `ubyte`s, the same
/// 4 bytes as `Rgba8`, with `rgba` swizzles from the default `xyzw` names.
alias Px = Vector!(ubyte, 4);
static assert(Px.sizeof == 4);

/// The accumulator a blur needs: the same vector, widened.
alias Px32 = Vector!(uint, 4);

enum size_t width = 8;
enum size_t height = 6;

ubyte sample(size_t y, size_t x, size_t c) @safe pure nothrow @nogc
    => cast(ubyte) ((x * 37 + y * 101 + c * 59 + x * y * 13) & 0xFF);

/// `(v * a + 127) / 255`, the rounded 8-bit premultiply.
ubyte mul8(uint v, uint a) @safe pure nothrow @nogc => cast(ubyte) ((v * a + 127) / 255);

// ---------------------------------------------------------------- per-pixel map

Rgba8 premultiply(Rgba8 p) @safe pure nothrow @nogc
    => Rgba8(mul8(p.r, p.a), mul8(p.g, p.a), mul8(p.b, p.a), p.a);

/// The map is lazy (`src.map!premultiply` is a view); assigning it to `dst[]`
/// runs it. No allocation, no copy of `src`.
void premultiplyInto(Slice!(const(Rgba8)*, 2) src, Slice!(Rgba8*, 2) dst) @safe pure nothrow @nogc
{
    dst[] = src.map!premultiply;
}

/// The same with `Vector` arithmetic: widen to `uint` lanes, multiply the
/// `rgb` swizzle by `a`, narrow back. `Vector` has no converting constructor,
/// so both conversions are spelled per component.
Px premultiplyVec(Px p) @safe pure nothrow @nogc
{
    const w = Px32(p.x, p.y, p.z, p.w);
    const rgb = (w.rgb * w.a + 127u) / 255u;
    return Px(cast(ubyte) rgb.x, cast(ubyte) rgb.y, cast(ubyte) rgb.z, p.w);
}

void premultiplyVecInto(Slice!(const(Px)*, 2) src, Slice!(Px*, 2) dst) @safe pure nothrow @nogc
{
    dst[] = src.map!premultiplyVec;
}

// ---------------------------------------------------------------- 3x3 box blur

/// Mean of one 3x3 window of `Rgba8`, channel by channel, rounded.
Rgba8 boxMean(W)(W w)
{
    uint r, g, b, a;
    foreach (p; w.flattened)
    {
        r += p.r;
        g += p.g;
        b += p.b;
        a += p.a;
    }
    return Rgba8(cast(ubyte) ((r + 4) / 9), cast(ubyte) ((g + 4) / 9), cast(ubyte) ((b + 4) / 9),
        cast(ubyte) ((a + 4) / 9));
}

/// The blur writes the interior: `windows(3, 3)` has `(h - 2) x (w - 2)`
/// windows, one per interior pixel, each a 3x3 view of `src`.
void boxBlurInto(Slice!(const(Rgba8)*, 2) src, Slice!(Rgba8*, 2) dst) @safe pure nothrow @nogc
{
    dst[1 .. $ - 1, 1 .. $ - 1] = src.windows(3, 3).map!(w => boxMean(w));
}

/// The same with `Vector` accumulation: one `+=` per pixel instead of four.
Px boxMeanVec(W)(W w)
{
    Px32 acc;
    foreach (p; w.flattened)
        acc += Px32(p.x, p.y, p.z, p.w);
    const m = (acc + 4u) / 9u;
    return Px(cast(ubyte) m.x, cast(ubyte) m.y, cast(ubyte) m.z, cast(ubyte) m.w);
}

void boxBlurVecInto(Slice!(const(Px)*, 2) src, Slice!(Px*, 2) dst) @safe pure nothrow @nogc
{
    dst[1 .. $ - 1, 1 .. $ - 1] = src.windows(3, 3).map!(w => boxMeanVec(w));
}

/// One 8-bit plane, `windows` form: the kernel the generated-code section reads.
void blurPlaneMir(Slice!(const(ubyte)*, 2) src, Slice!(ubyte*, 2) dst) @safe pure nothrow @nogc
{
    dst[1 .. $ - 1, 1 .. $ - 1] = src.windows(3, 3).map!((w) {
        uint s = 0;
        foreach (v; w.flattened)
            s += v;
        return cast(ubyte) ((s + 4) / 9);
    });
}

/// One 8-bit plane, hand-written loops over the same `Slice` (rows indexed
/// through the slice, columns through a plain array row).
void blurPlaneLoop(Slice!(const(ubyte)*, 2) src, Slice!(ubyte*, 2) dst) @safe pure nothrow @nogc
{
    foreach (y; 1 .. src.length!0 - 1)
    {
        const(ubyte)[] r0 = src[y - 1].field, r1 = src[y].field, r2 = src[y + 1].field;
        ubyte[] o = dst[y].field;
        foreach (x; 1 .. src.length!1 - 1)
        {
            const uint s = r0[x - 1] + r0[x] + r0[x + 1] + r1[x - 1] + r1[x] + r1[x + 1] + r2[x - 1] + r2[x]
                + r2[x + 1];
            o[x] = cast(ubyte) ((s + 4) / 9);
        }
    }
}

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

void main() @safe
{
    // Interleaved storage, filled once; three views over it.
    auto bytes = new ubyte[](width * height * 4);
    foreach (y; 0 .. height)
        foreach (x; 0 .. width)
            foreach (c; 0 .. 4)
                bytes[(y * width + x) * 4 + c] = sample(y, x, c);

    auto img = (cast(Rgba8[]) bytes).sliced(height, width);
    auto imgV = (cast(Px[]) bytes).sliced(height, width);
    auto img3 = bytes.sliced(height, width, 4);
    writefln("source         fnv1a %08x  img[1, 2] %s  imgV[1, 2] %s", fnv1a(img3), img[1, 2], imgV[1, 2].array);

    // Per-pixel map.
    auto pm = new Rgba8[](width * height).sliced(height, width);
    auto pmV = new Px[](width * height).sliced(height, width);
    premultiplyInto(img, pm);
    premultiplyVecInto(imgV, pmV);
    auto pmBytes = (cast(ubyte[]) pm.field).sliced(height, width, 4);
    auto pmVBytes = (cast(ubyte[]) pmV.field).sliced(height, width, 4);
    writefln("premultiplied  fnv1a %08x  struct == Vector: %s  pm[1, 2] %s", fnv1a(pmBytes),
        pmBytes == pmVBytes, pm[1, 2]);

    // 3x3 box blur, border copied from the source.
    auto bl = new Rgba8[](width * height).sliced(height, width);
    auto blV = new Px[](width * height).sliced(height, width);
    bl[] = img;
    blV[] = imgV;
    boxBlurInto(img, bl);
    boxBlurVecInto(imgV, blV);
    auto blBytes = (cast(ubyte[]) bl.field).sliced(height, width, 4);
    auto blVBytes = (cast(ubyte[]) blV.field).sliced(height, width, 4);
    writefln("box blur       fnv1a %08x  struct == Vector: %s  bl[2, 3] %s", fnv1a(blBytes),
        blBytes == blVBytes, bl[2, 3]);

    // One plane (the red channel, copied out contiguous), both blur forms.
    auto red = new ubyte[](width * height).sliced(height, width);
    red[] = img3[0 .. $, 0 .. $, 0];
    auto a = new ubyte[](width * height).sliced(height, width);
    auto b = new ubyte[](width * height).sliced(height, width);
    a[] = red;
    b[] = red;
    blurPlaneMir(red, a);
    blurPlaneLoop(red, b);
    writefln("plane blur     fnv1a %08x  windows == loop: %s  red-channel of RGBA blur agrees: %s", fnv1a(a), a == b,
        a == blBytes[0 .. $, 0 .. $, 0]);
}
