#!/usr/bin/env dub
/+ dub.sdl:
    name "check_test_pattern"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Checks a screen capture of the `sparkles.vulkan_wsi.test_pattern` against the
geometry the app reported.

    check-test-pattern <capture.raw> <width>x<height> <left>,<top>,<right>,<bottom>

The capture is `adb exec-out screencap` without `-p`: a header of width,
height, pixel format (and, from Android 9, colour space) as 32-bit words,
then RGBA8888 rows. The geometry is the app's `pattern:` log line: the display
size it drew for and the safe insets. Every check samples pixels where the
pattern's design puts something exact, so a stretched, scaled, cropped,
mis-rotated or stale image fails one of them:

- the capture is the display size, so nothing letterboxed or scaled it;
- each corner crosshair has its colour (red top left, green top right, blue
    bottom left, white bottom right), so the pattern is upright;
- the amber border sits exactly on the safe rectangle's edges;
- the insets hold the caution hatch;
- portrait: the circle crosses its radius at the same distance in all four
    directions (no stretch), the side gratings alternate exactly one pixel
    (no scaling), and the grey ladder's steps hold their code values;
- landscape: the colour bars hold their 75% and 100% code values.

Prints one `ok:` line, or every failure and exits 1.
*/
module check_test_pattern;

import std.algorithm : all, any, map;
import std.array : array;
import std.conv : to;
import std.file : read;
import std.format : format;
import std.math : abs, round;
import std.stdio : stderr, writeln;
import std.string : split;

struct Rgb
{
    int r, g, b;

    string toString() const => format!"(%d,%d,%d)"(r, g, b);
}

struct Capture
{
    int width, height;
    const(ubyte)[] pixels;

    Rgb at(int x, int y) const
    {
        const i = (cast(size_t) y * width + x) * 4;
        return Rgb(pixels[i], pixels[i + 1], pixels[i + 2]);
    }
}

int main(string[] args)
{
    if (args.length != 4)
    {
        stderr.writeln("usage: check-test-pattern <capture.raw> <W>x<H> <l>,<t>,<r>,<b>");
        return 2;
    }
    const bytes = cast(const(ubyte)[]) read(args[1]);
    uint word(size_t i) => bytes[i * 4] | bytes[i * 4 + 1] << 8
        | bytes[i * 4 + 2] << 16 | bytes[i * 4 + 3] << 24;
    auto capture = Capture(cast(int) word(0), cast(int) word(1));
    const header = bytes.length - cast(size_t) capture.width * capture.height * 4;
    if (header != 12 && header != 16)
    {
        stderr.writeln("not an RGBA8888 screencap: ", bytes.length, " bytes for ",
            capture.width, "x", capture.height);
        return 2;
    }
    capture.pixels = bytes[header .. $];

    const size = args[2].split("x").map!(to!int).array;
    const inset = args[3].split(",").map!(to!int).array;
    const W = size[0], H = size[1];
    const l = inset[0], t = inset[1], r = inset[2], b = inset[3];

    string[] failures;
    void expect(bool holds, lazy string what)
    {
        if (!holds)
            failures ~= what;
    }

    expect(capture.width == W && capture.height == H,
        format!"the capture is %dx%d, the pattern drew for %dx%d: something scaled or letterboxed it"(
            capture.width, capture.height, W, H));
    if (failures.length)
        return report(failures);

    static bool near(Rgb c, int r, int g, int b, int tolerance = 40)
        => abs(c.r - r) <= tolerance && abs(c.g - g) <= tolerance && abs(c.b - b) <= tolerance;

    // Corners: the pattern's orientation, and its reach to the panel's edges.
    const corners = [
        [0, 0, 255, 0, 0], [W - 1, 0, 0, 255, 0],
        [0, H - 1, 0, 0, 255], [W - 1, H - 1, 255, 255, 255],
    ];
    foreach (c; corners)
    {
        const got = capture.at(c[0], c[1]);
        expect(near(got, c[2], c[3], c[4]), format!"corner (%d,%d) is %s, not (%d,%d,%d)"(
            c[0], c[1], got, c[2], c[3], c[4]));
    }

    // The amber border on each edge of the safe rectangle, sampled at a
    // third of the way along (clear of the centre's camera cutout and the
    // gesture pill), with the pixel just outside it not amber.
    static bool amber(Rgb c) => c.r > 220 && c.g > 170 && c.g < 240 && c.b < 60;
    const x3 = l + (W - l - r) / 3, y3 = t + (H - t - b) / 3;
    expect(amber(capture.at(l, y3)) && amber(capture.at(l + 1, y3)),
        format!"no amber border at the safe left edge x=%d"(l));
    expect(amber(capture.at(W - r - 1, y3)), format!"no amber border at the safe right edge x=%d"(W - r - 1));
    expect(amber(capture.at(x3, t)) && amber(capture.at(x3, t + 1)),
        format!"no amber border at the safe top edge y=%d"(t));
    expect(amber(capture.at(x3, H - b - 1)), format!"no amber border at the safe bottom edge y=%d"(H - b - 1));
    if (l > 0)
        expect(!amber(capture.at(l - 1, y3)), "the amber border spills left of the safe area");
    if (t > 0)
        expect(!amber(capture.at(x3, t - 1)), "the amber border spills above the safe area");

    // The hatch: inside each non-empty inset band, a run that holds both
    // the dark red and black stripes (system UI may draw over parts of it).
    static bool hatchRed(Rgb c) => c.r > 110 && c.r < 170 && c.g < 40 && c.b < 40;
    static bool black(Rgb c) => c.r < 30 && c.g < 30 && c.b < 30;
    void hatch(int x0, int y0, int dx, int dy, string band)
    {
        bool red, dark;
        foreach (i; 0 .. 96)
        {
            const c = capture.at(x0 + i * dx, y0 + i * dy);
            red |= hatchRed(c);
            dark |= black(c);
        }
        expect(red && dark, "no caution hatch in the " ~ band ~ " inset");
    }
    if (t > 4)
        hatch(x3, t / 2, 1, 0, "top");
    if (b > 4)
        hatch(x3, H - b / 2 - 1, 1, 0, "bottom");
    if (l > 4)
        hatch(l / 2, y3, 0, 1, "left");
    if (r > 4)
        hatch(W - r / 2 - 1, y3, 0, 1, "right");

    const sw = W - l - r, sh = H - t - b;
    if (H > W)
        portrait(capture, l, t, sw, sh, &expect);
    else
        landscape(capture, l, t, sw, sh, &expect);

    if (failures.length)
        return report(failures);
    writeln(format!"ok: test pattern %s %dx%d, safe %d,%d,%d,%d: corners, border, hatch and layout exact"(
        H > W ? "portrait" : "landscape", W, H, l, t, r, b));
    return 0;
}

int report(string[] failures)
{
    foreach (f; failures)
        stderr.writeln("FAIL: ", f);
    return 1;
}

alias Expect = void delegate(bool, lazy string);

void portrait(in Capture c, int l, int t, int sw, int sh, Expect expect)
{
    // The circle: radius 0.4 × the safe width around the safe centre. Find
    // the green ring outward from the centre in all four directions; equal
    // distances mean the image was not stretched.
    static bool green(Rgb p) => p.g > 200 && p.r < 60 && p.b < 60;
    const cx = l + sw / 2, cy = t + sh / 2;
    const radius = 0.4 * sw;
    int ring(int dx, int dy)
    {
        foreach (d; cast(int)(radius * 0.8) .. cast(int)(radius * 1.2))
            if (green(c.at(cx + d * dx, cy + d * dy)))
                return d;
        return -1;
    }
    const distances = [ring(1, 0), ring(-1, 0), ring(0, 1), ring(0, -1)];
    expect(distances.all!(d => d > 0 && abs(d - radius) <= 3),
        format!"the circle's radius should be %.1f in every direction, found %s"(radius, distances));

    // The gratings: exactly alternating 1-pixel rows near the left edge.
    static bool white(Rgb p) => p.r > 225 && p.g > 225 && p.b > 225;
    static bool dark(Rgb p) => p.r < 30 && p.g < 30 && p.b < 30;
    const gx = l + 12;
    bool alternates = true;
    foreach (y; cy - 32 .. cy + 32)
    {
        const p = c.at(gx, y);
        const local = y - t;
        alternates &= (local & 1) == 0 ? white(p) : dark(p);
    }
    expect(alternates, "the 1-pixel gratings are not exact: the image was scaled or filtered");

    // The ladder: step k holds code value k × 255 / 31.
    const top = sh / 10, height = sh - 2 * top;
    int worst;
    foreach (k; 0 .. 32)
    {
        const y = t + top + (2 * k + 1) * height / 64;
        const p = c.at(cx, y);
        const want = cast(int) round(k * 255.0 / 31.0);
        foreach (v; [p.r, p.g, p.b])
            if (abs(v - want) > worst)
                worst = abs(v - want);
    }
    expect(worst <= 4, format!"the grey ladder is off by up to %d code values"(worst));
}

void landscape(in Capture c, int l, int t, int sw, int sh, Expect expect)
{
    // Colour bars: 75% in the upper band, 100% below it.
    const bits = [[1, 1, 1], [1, 1, 0], [0, 1, 1], [0, 1, 0],
        [1, 0, 1], [1, 0, 0], [0, 0, 1], [0, 0, 0]];
    foreach (i, rgb; bits)
    {
        const x = l + (2 * cast(int) i + 1) * sw / 16;
        foreach (band; [[0.25, 191.0], [0.52, 255.0]])
        {
            const p = c.at(x, t + cast(int)(band[0] * sh));
            const level = cast(int) band[1];
            const ok = abs(p.r - rgb[0] * level) <= 6 && abs(p.g - rgb[1] * level) <= 6
                && abs(p.b - rgb[2] * level) <= 6;
            expect(ok, format!"colour bar %d at %d%% is %s"(i, cast(int)(band[1] * 100 / 255), p));
        }
    }
}
