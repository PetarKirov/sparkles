#!/usr/bin/env dub
/+ dub.sdl:
    name "font_libraries_outline_sink_raster"
    targetPath "build"
    libs "harfbuzz"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * From outline to pixels with HarfBuzz as the only C dependency — the outline
 * arrives through a callback sink, and the rasterizer is ~100 lines of D.
 *
 * Demonstrates three of the survey's questions against a real font:
 *
 *   RQ6 — outline access as a SINK. `hb_font_draw_glyph` drives five
 *         callbacks (`move_to`, `line_to`, `quadratic_to`, `cubic_to`,
 *         `close_path`) in the font's scaled units; the program counts the
 *         segments by kind, which tells TrueType (`glyf`, quadratic) from CFF
 *         (cubic) without asking.
 *   RQ3 — variation coordinates reach OUTLINES through the same `hb_font_t`
 *         that shaping uses: `hb_font_set_variations(wght=…)` once, and both
 *         the advance and the drawn contours move. The glyph is rendered at
 *         the axis minimum and maximum side by side.
 *   RQ2 — a from-scratch CPU rasterizer is small. `Rasterizer` below is the
 *         signed-area accumulation algorithm of font-rs (Raph Levien, 2016;
 *         the same algorithm stb_truetype v2, fontdue, ab_glyph_rasterizer and
 *         Go's x/image/vector use): each line deposits signed area into a
 *         per-row accumulation buffer, and one prefix sum per row yields exact
 *         coverage. Curves are flattened to lines first. No hinting, no
 *         gamma — those are the parts that are not small.
 *
 * Companion to docs/research/font-libraries/comparison.md (RQ2, RQ3, RQ6),
 * harfbuzz.md § 5, and fontdue.md / ab-glyph.md / stb-truetype.md on the
 * accumulation rasterizer.
 *
 * Run with: dub run --single outline-sink-raster.d [-- /path/to/font.ttf [char]]
 *
 * Font resolution: the first argument if given, else `fc-match -f %{file}
 * "Noto Sans"`. If nothing resolves (no fontconfig on the host), prints a
 * `SKIP:` line and exits 0 so CI stays green.
 */
module font_libraries_outline_sink_raster;

import std.algorithm : max, min;
import std.file : exists;
import std.math : abs, ceil, floor, sqrt;
import std.process : execute;
import std.stdio : write, writeln, writefln;
import std.string : strip, toStringz;

// ---------------------------------------------------------------------------
// HarfBuzz C ABI, the subset this program needs. Only opaque handles and
// scalars cross; `hb_draw_state_t` is received by pointer and never read.
// ---------------------------------------------------------------------------
extern (C) nothrow @nogc
{
    struct hb_blob_t;
    struct hb_face_t;
    struct hb_font_t;
    struct hb_draw_funcs_t;
    struct hb_draw_state_t;

    alias hb_codepoint_t = uint;
    alias hb_tag_t = uint;

    struct hb_variation_t { hb_tag_t tag; float value; }
    struct hb_ot_var_axis_info_t
    {
        uint axis_index; hb_tag_t tag; uint name_id; uint flags;
        float min_value, default_value, max_value; uint reserved;
    }

    alias MoveToFn = void function(hb_draw_funcs_t*, void*, hb_draw_state_t*,
        float, float, void*);
    alias QuadToFn = void function(hb_draw_funcs_t*, void*, hb_draw_state_t*,
        float, float, float, float, void*);
    alias CubicToFn = void function(hb_draw_funcs_t*, void*, hb_draw_state_t*,
        float, float, float, float, float, float, void*);
    alias CloseFn = void function(hb_draw_funcs_t*, void*, hb_draw_state_t*, void*);

    hb_blob_t* hb_blob_create_from_file(const(char)*);
    void hb_blob_destroy(hb_blob_t*);
    hb_face_t* hb_face_create(hb_blob_t*, uint);
    void hb_face_destroy(hb_face_t*);
    uint hb_face_get_upem(const(hb_face_t)*);
    hb_font_t* hb_font_create(hb_face_t*);
    void hb_font_destroy(hb_font_t*);
    void hb_font_set_scale(hb_font_t*, int, int);
    void hb_font_set_variations(hb_font_t*, const(hb_variation_t)*, uint);
    int hb_font_get_nominal_glyph(hb_font_t*, hb_codepoint_t, hb_codepoint_t*);
    int hb_font_get_glyph_h_advance(hb_font_t*, hb_codepoint_t);
    uint hb_ot_var_get_axis_infos(hb_face_t*, uint, uint*, hb_ot_var_axis_info_t*);

    hb_draw_funcs_t* hb_draw_funcs_create();
    void hb_draw_funcs_destroy(hb_draw_funcs_t*);
    void hb_draw_funcs_make_immutable(hb_draw_funcs_t*);
    void hb_draw_funcs_set_move_to_func(hb_draw_funcs_t*, MoveToFn, void*, void*);
    void hb_draw_funcs_set_line_to_func(hb_draw_funcs_t*, MoveToFn, void*, void*);
    void hb_draw_funcs_set_quadratic_to_func(hb_draw_funcs_t*, QuadToFn, void*, void*);
    void hb_draw_funcs_set_cubic_to_func(hb_draw_funcs_t*, CubicToFn, void*, void*);
    void hb_draw_funcs_set_close_path_func(hb_draw_funcs_t*, CloseFn, void*, void*);
    void hb_font_draw_glyph(hb_font_t*, hb_codepoint_t, hb_draw_funcs_t*, void*);
}

// ---------------------------------------------------------------------------
// The rasterizer: signed-area accumulation (font-rs). Coordinates are pixels,
// y-down, origin at the bitmap's top-left.
// ---------------------------------------------------------------------------
struct Rasterizer
{
    int w, h;
    float[] acc; // (w + 2) per row of headroom for the rightmost deposits

    this(int w, int h) { this.w = w; this.h = h; acc = new float[(w + 2) * h]; acc[] = 0; }

    void line(float x0, float y0, float x1, float y1) @safe pure nothrow @nogc
    {
        if (y0 == y1) return;
        float dir = 1;
        if (y0 > y1) { dir = -1; swap(x0, x1); swap(y0, y1); }
        const dxdy = (x1 - x0) / (y1 - y0);
        float x = x0;
        if (y0 < 0) x -= y0 * dxdy;
        const yEnd = min(h, cast(int) ceil(y1));
        for (int y = max(0, cast(int) y0); y < yEnd; ++y)
        {
            const row = y * (w + 2);
            const dy = min(y + 1.0f, y1) - max(cast(float) y, y0);
            const xnext = x + dxdy * dy;
            const d = dy * dir;
            const xa = min(x, xnext), xb = max(x, xnext);
            const xaFloor = floor(xa);
            const xai = cast(int) xaFloor;
            const xbCeil = ceil(xb);
            const xbi = cast(int) xbCeil;
            if (xai < 0 || xbi > w + 1) { x = xnext; continue; }
            if (xbi <= xai + 1)
            {
                // The line stays inside one pixel column on this row.
                const xmf = 0.5f * (x + xnext) - xaFloor;
                acc[row + xai] += d - d * xmf;
                acc[row + xai + 1] += d * xmf;
            }
            else
            {
                // It crosses several columns: trapezoids at both ends, a
                // constant slope's worth of area in between.
                const s = 1.0f / (xb - xa);
                const xaf = xa - xaFloor;
                const a0 = 0.5f * s * (1 - xaf) * (1 - xaf);
                const xbf = xb - xbCeil + 1;
                const am = 0.5f * s * xbf * xbf;
                acc[row + xai] += d * a0;
                if (xbi == xai + 2)
                    acc[row + xai + 1] += d * (1 - a0 - am);
                else
                {
                    const a1 = s * (1.5f - xaf);
                    acc[row + xai + 1] += d * (a1 - a0);
                    foreach (xi; xai + 2 .. xbi - 1)
                        acc[row + xi] += d * s;
                    const a2 = a1 + (xbi - xai - 3) * s;
                    acc[row + xbi - 1] += d * (1 - a2 - am);
                }
                acc[row + xbi] += d * am;
            }
            x = xnext;
        }
    }

    /// One prefix sum per row turns deposited area into coverage in [0, 1].
    float[] coverage() const @safe pure nothrow
    {
        auto c = new float[w * h];
        foreach (y; 0 .. h)
        {
            float sum = 0;
            foreach (x; 0 .. w)
            {
                sum += acc[y * (w + 2) + x];
                c[y * w + x] = min(abs(sum), 1.0f);
            }
        }
        return c;
    }
}

void swap(ref float a, ref float b) @safe pure nothrow @nogc { const t = a; a = b; b = t; }

// ---------------------------------------------------------------------------
// The sink: HarfBuzz callbacks → flattened lines into the rasterizer.
// ---------------------------------------------------------------------------
struct Sink
{
    Rasterizer* r;
    float originX, baseline; // font units are y-up; flip here, once
    float px, py, startX, startY;
    int moves, lines, quads, cubics;

    float sx(float x) const nothrow @nogc => originX + x;
    float sy(float y) const nothrow @nogc => baseline - y;

    void lineTo(float x, float y) nothrow @nogc
    {
        r.line(sx(px), sy(py), sx(x), sy(y));
        px = x; py = y;
    }
}

enum flattenSteps = 8; // uniform subdivision; adaptive flattening is a refinement

extern (C) nothrow @nogc void onMove(hb_draw_funcs_t*, void* data, hb_draw_state_t*, float x, float y, void*)
{
    auto s = cast(Sink*) data;
    ++s.moves;
    s.px = s.startX = x; s.py = s.startY = y;
}

extern (C) nothrow @nogc void onLine(hb_draw_funcs_t*, void* data, hb_draw_state_t*, float x, float y, void*)
{
    auto s = cast(Sink*) data;
    ++s.lines;
    s.lineTo(x, y);
}

extern (C) nothrow @nogc void onQuad(hb_draw_funcs_t*, void* data, hb_draw_state_t*,
    float cx, float cy, float x, float y, void*)
{
    auto s = cast(Sink*) data;
    ++s.quads;
    const x0 = s.px, y0 = s.py;
    foreach (i; 1 .. flattenSteps + 1)
    {
        const t = cast(float) i / flattenSteps, u = 1 - t;
        s.lineTo(u * u * x0 + 2 * u * t * cx + t * t * x, u * u * y0 + 2 * u * t * cy + t * t * y);
    }
}

extern (C) nothrow @nogc void onCubic(hb_draw_funcs_t*, void* data, hb_draw_state_t*,
    float c1x, float c1y, float c2x, float c2y, float x, float y, void*)
{
    auto s = cast(Sink*) data;
    ++s.cubics;
    const x0 = s.px, y0 = s.py;
    foreach (i; 1 .. flattenSteps + 1)
    {
        const t = cast(float) i / flattenSteps, u = 1 - t;
        s.lineTo(u * u * u * x0 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x,
            u * u * u * y0 + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y);
    }
}

extern (C) nothrow @nogc void onClose(hb_draw_funcs_t*, void* data, hb_draw_state_t*, void*)
{
    auto s = cast(Sink*) data;
    if (s.px != s.startX || s.py != s.startY)
        s.lineTo(s.startX, s.startY);
}

// ---------------------------------------------------------------------------

string resolveFont(string[] args)
{
    if (args.length > 1 && exists(args[1]))
        return args[1];
    try
    {
        auto r = execute(["fc-match", "-f", "%{file}", "Noto Sans"]);
        if (r.status == 0 && r.output.strip.length && exists(r.output.strip))
            return r.output.strip;
    }
    catch (Exception) {}
    return null;
}

enum ramp = " .:-=+*#%@";

/// Draws `cp` at `ppem` pixels into a `w`×`h` coverage bitmap.
float[] render(hb_font_t* font, hb_draw_funcs_t* funcs, dchar cp, int w, int h,
    out Sink sink, out int advance)
{
    hb_codepoint_t gid;
    hb_font_get_nominal_glyph(font, cp, &gid);
    advance = hb_font_get_glyph_h_advance(font, gid);
    auto r = new Rasterizer(w, h);
    sink = Sink(r, 1, h * 0.75f);
    hb_font_draw_glyph(font, gid, funcs, &sink);
    return r.coverage();
}

int main(string[] args)
{
    const path = resolveFont(args);
    if (path is null)
    {
        writeln("SKIP: no font file resolved (pass a path, or install fontconfig)");
        return 0;
    }
    const dchar cp = args.length > 2 && args[2].length ? args[2][0] : 'g';
    enum ppem = 28, w = 24, h = 32;

    auto blob = hb_blob_create_from_file(path.toStringz);
    scope (exit) hb_blob_destroy(blob);
    auto face = hb_face_create(blob, 0);
    scope (exit) hb_face_destroy(face);
    auto font = hb_font_create(face);
    scope (exit) hb_font_destroy(font);
    // Scale so one output unit is one pixel: shaping AND drawing now speak px.
    hb_font_set_scale(font, ppem, ppem);

    auto funcs = hb_draw_funcs_create();
    scope (exit) hb_draw_funcs_destroy(funcs);
    hb_draw_funcs_set_move_to_func(funcs, &onMove, null, null);
    hb_draw_funcs_set_line_to_func(funcs, &onLine, null, null);
    hb_draw_funcs_set_quadratic_to_func(funcs, &onQuad, null, null);
    hb_draw_funcs_set_cubic_to_func(funcs, &onCubic, null, null);
    hb_draw_funcs_set_close_path_func(funcs, &onClose, null, null);
    hb_draw_funcs_make_immutable(funcs);

    // Find `wght`; a static font renders once at its only weight.
    hb_ot_var_axis_info_t[16] axes;
    uint n = axes.length;
    hb_ot_var_get_axis_infos(face, 0, &n, axes.ptr);
    float[] weights;
    foreach (a; axes[0 .. n])
        if (a.tag == ('w' << 24 | 'g' << 16 | 'h' << 8 | 't'))
            weights = [a.min_value, a.max_value];

    writefln("font: %s", path);
    writefln("glyph %s at %d ppem; %s", cast(dchar) cp, ppem,
        weights.length ? "variable: wght min vs max" : "static face (no wght axis)");

    float[][] bitmaps;
    foreach (i, wght; weights.length ? weights : [float.nan])
    {
        if (wght == wght) // not NaN
        {
            auto v = hb_variation_t('w' << 24 | 'g' << 16 | 'h' << 8 | 't', wght);
            hb_font_set_variations(font, &v, 1);
        }
        Sink sink;
        int adv;
        bitmaps ~= render(font, funcs, cp, w, h, sink, adv);
        float ink = 0;
        foreach (c; bitmaps[$ - 1]) ink += c;
        writefln("  %-10s advance %2d px  ink %6.1f px²  segments: %d move, %d line, %d quad, %d cubic",
            wght == wght ? "wght " ~ (cast(int) wght).to!string : "default", adv, ink,
            sink.moves, sink.lines, sink.quads, sink.cubics);
    }

    foreach (y; 0 .. h)
    {
        bool blank = true;
        foreach (b; bitmaps) foreach (x; 0 .. w) if (b[y * w + x] > 0.05f) blank = false;
        if (blank) continue;
        foreach (bi, b; bitmaps)
        {
            write(bi ? "   " : "  ");
            foreach (x; 0 .. w)
                write(ramp[min(ramp.length - 1, cast(size_t)(b[y * w + x] * (ramp.length - 1) + 0.5f))]);
        }
        writeln();
    }
    return 0;
}

import std.conv : to;
