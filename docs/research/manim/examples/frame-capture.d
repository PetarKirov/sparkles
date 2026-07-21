#!/usr/bin/env dub
/+ dub.sdl:
    name "manim_frame_capture"
    targetPath "build"
+/
/**
 * The native output pipeline in miniature: rasterise a frame into an RGBA
 * buffer, read the pixels back, and reduce them to a checksum — the exact
 * shape of the "render → framebuffer readback → encode" path every native
 * Manim-class engine runs, minus the GPU and the codec.
 *
 * The *output & encoding* axis of the analysis spine. A real backend fills
 * this buffer for you: Cairo hands back `cairo_image_surface_get_data`,
 * raylib exposes it through `TakeScreenshot` / an offscreen `RenderTexture`
 * (already exercised in this repo's `apps/terminal/src/app.d`), and the raw
 * RGBA bytes are then piped to ffmpeg's stdin (`-f rawvideo -pix_fmt rgba`,
 * ManimGL's exact command) or handed to libav. This probe stands in a pure
 * software rasteriser so it compiles and runs with zero dependencies and no
 * display, while grounding the claim that a frame is *just an addressable
 * RGBA buffer* an encoder consumes — the interface the proposal's renderer
 * `readback()` capability returns.
 *
 * It rasterises a background clear plus a filled disc (analytic coverage AA
 * on the boundary — the same anti-aliasing concern §axis 3 raises), reads the
 * buffer back, counts non-background pixels, and prints a deterministic
 * FNV-1a checksum. Determinism of this checksum across runs is precisely what
 * makes per-`play()` content-hash caching (§axis 8) correct.
 *
 * Companion to docs/research/manim/rendering-backends/gpu-vector.md
 *   § "Framebuffer readback" and docs/research/manim/video-encoding.md
 *   § "The raw-RGBA pipe".
 * Run with: dub run --single frame-capture.d
 *
 * Portability: pure software rasterisation, no GPU / display / external
 * dependency — deterministic on every host (unlike a live raylib window,
 * which would need a display and is covered by apps/terminal instead).
 */
module manim_frame_capture;

import std.math : sqrt;
import std.stdio : writefln, writeln;

enum W = 64, H = 48;

struct Framebuffer
{
    ubyte[W * H * 4] px; // RGBA8, row-major

    void clear(ubyte r, ubyte g, ubyte b, ubyte a) @safe pure nothrow @nogc
    {
        foreach (i; 0 .. W * H)
        {
            px[i * 4 + 0] = r;
            px[i * 4 + 1] = g;
            px[i * 4 + 2] = b;
            px[i * 4 + 3] = a;
        }
    }

    /// Alpha-composite a color over pixel (x,y) with coverage in [0,1].
    void blend(int x, int y, ubyte r, ubyte g, ubyte b, double cov) @safe pure nothrow @nogc
    {
        if (x < 0 || x >= W || y < 0 || y >= H || cov <= 0)
            return;
        const i = (y * W + x) * 4;
        void over(size_t k, ubyte src)
        {
            px[i + k] = cast(ubyte)(src * cov + px[i + k] * (1 - cov) + 0.5);
        }

        over(0, r);
        over(1, g);
        over(2, b);
    }

    /// Filled disc with 1px analytic-coverage anti-aliased edge.
    void disc(double cx, double cy, double rad, ubyte r, ubyte g, ubyte b) @safe pure nothrow @nogc
    {
        foreach (y; 0 .. H)
            foreach (x; 0 .. W)
            {
                const d = sqrt((x + 0.5 - cx) ^^ 2 + (y + 0.5 - cy) ^^ 2);
                const cov = d <= rad - 0.5 ? 1.0 : (d >= rad + 0.5 ? 0.0 : rad + 0.5 - d);
                blend(x, y, r, g, b, cov);
            }
    }
}

/// FNV-1a over the whole readback buffer — a stand-in for a content hash.
ulong fnv1a(in ubyte[] bytes) @safe pure nothrow @nogc
{
    ulong h = 0xcbf29ce484222325;
    foreach (b; bytes)
    {
        h ^= b;
        h *= 0x100000001b3;
    }
    return h;
}

int main() @safe
{
    Framebuffer fb;
    fb.clear(16, 16, 24, 255); // dark background
    fb.disc(W / 2.0, H / 2.0, 16, 240, 120, 40); // one filled, AA-edged disc

    // "Read back" the buffer — exactly what an encoder is handed.
    const bytes = fb.px[];
    size_t nonBg;
    foreach (i; 0 .. W * H)
        if (!(bytes[i * 4] == 16 && bytes[i * 4 + 1] == 16 && bytes[i * 4 + 2] == 24))
            nonBg++;

    writeln("== software frame capture (stand-in for Cairo/raylib readback) ==");
    writefln("  frame            : %d x %d RGBA8 (%d bytes)", W, H, bytes.length);
    writefln("  drawn pixels     : %d / %d (disc + AA edge over background)", nonBg, W * H);
    writefln("  readback checksum: 0x%016x (FNV-1a — deterministic across runs)", fnv1a(bytes));
    writeln("  → these raw RGBA bytes are the input to `ffmpeg -f rawvideo -pix_fmt rgba`");
    writeln("    or libav; the stable checksum is what makes play()-level caching correct.");
    return 0;
}
