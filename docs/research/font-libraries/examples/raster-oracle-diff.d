#!/usr/bin/env dub
/+ dub.sdl:
    name "font_libraries_raster_oracle_diff"
    targetPath "build"
    libs "harfbuzz" "freetype"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * How close is a signed-area accumulation rasterizer to FreeType? Renders
 * every glyph of each face at 12, 16, 24 and 48 pixels per em, unhinted, both
 * with the rasterizer of outline-sink-raster.d and with FreeType
 * (`FT_LOAD_NO_HINTING | FT_LOAD_RENDER`), and reports the distribution of
 * per-pixel coverage differences in 1/255 steps.
 *
 * Two configurations of the D side:
 *
 *   production  adaptive flattening to 0.02 px, and 4x4 supersampling for
 *               glyphs whose `glyf` data sets OVERLAP_SIMPLE (0x40 on the first
 *               point) or OVERLAP_COMPOUND (0x0400) — the rule FreeType's
 *               smooth renderer applies (ttgload.c, ftsmooth.c);
 *   ft-flatten  the same, but curves flattened by FreeType's own ftgrays.c
 *               rules. What remains is the rasterizers' arithmetic; the
 *               difference from `production` is FreeType's flattening error.
 *
 * FreeType is reached through hand-declared prototypes. Only the leading
 * fields of `FT_FaceRec` and `FT_GlyphSlotRec` are declared, and they are
 * checked against HarfBuzz's view of the same face before any glyph is
 * compared.
 *
 * Spike S2 of docs/specs/font/PLAN.md; docs/specs/font/testing.md § Raster
 * oracle records the result.
 *
 * Run with: dub run --single raster-oracle-diff.d [-- font.ttf ...]
 *
 * Font resolution: the arguments if given, else `fc-match -f %{file}
 * monospace`. If neither yields a readable file, prints a `SKIP:` line and
 * exits 0 so CI stays green.
 */
module font_libraries_raster_oracle_diff;

import core.stdc.config : c_long;
import std.algorithm : count, max, min, sort;
import std.file : exists, read;
import std.math : abs, ceil, floor, hypot, sqrt;
import std.path : baseName;
import std.process : execute;
import std.stdio : writefln, writeln;
import std.string : strip, toStringz;

// ---------------------------------------------------------------------------
// HarfBuzz and FreeType C ABIs, the subsets this program needs.
// ---------------------------------------------------------------------------
extern (C) nothrow @nogc
{
    struct hb_blob_t;
    struct hb_face_t;
    struct hb_font_t;
    struct hb_draw_funcs_t;
    struct hb_draw_state_t;

    alias MoveToFn = void function(hb_draw_funcs_t*, void*, hb_draw_state_t*, float, float, void*);
    alias QuadToFn = void function(hb_draw_funcs_t*, void*, hb_draw_state_t*,
        float, float, float, float, void*);
    alias CubicToFn = void function(hb_draw_funcs_t*, void*, hb_draw_state_t*,
        float, float, float, float, float, float, void*);
    alias CloseFn = void function(hb_draw_funcs_t*, void*, hb_draw_state_t*, void*);

    hb_blob_t* hb_blob_create_from_file(const(char)*);
    void hb_blob_destroy(hb_blob_t*);
    uint hb_blob_get_length(hb_blob_t*);
    hb_face_t* hb_face_create(hb_blob_t*, uint);
    void hb_face_destroy(hb_face_t*);
    uint hb_face_get_upem(const(hb_face_t)*);
    uint hb_face_get_glyph_count(const(hb_face_t)*);
    hb_font_t* hb_font_create(hb_face_t*);
    void hb_font_destroy(hb_font_t*);
    void hb_font_set_scale(hb_font_t*, int, int);
    hb_draw_funcs_t* hb_draw_funcs_create();
    void hb_draw_funcs_destroy(hb_draw_funcs_t*);
    void hb_draw_funcs_set_move_to_func(hb_draw_funcs_t*, MoveToFn, void*, void*);
    void hb_draw_funcs_set_line_to_func(hb_draw_funcs_t*, MoveToFn, void*, void*);
    void hb_draw_funcs_set_quadratic_to_func(hb_draw_funcs_t*, QuadToFn, void*, void*);
    void hb_draw_funcs_set_cubic_to_func(hb_draw_funcs_t*, CubicToFn, void*, void*);
    void hb_draw_funcs_set_close_path_func(hb_draw_funcs_t*, CloseFn, void*, void*);
    void hb_font_draw_glyph(hb_font_t*, uint, hb_draw_funcs_t*, void*);

    // freetype.h and ftimage.h. Leading fields only: D never allocates these.
    struct FT_Generic { void* data; void* finalizer; }
    struct FT_BBox { c_long xMin, yMin, xMax, yMax; }
    struct FT_Vector { c_long x, y; }
    struct FT_Glyph_Metrics
    {
        c_long width, height, horiBearingX, horiBearingY, horiAdvance,
            vertBearingX, vertBearingY, vertAdvance;
    }
    struct FT_Bitmap
    {
        uint rows, width;
        int pitch;
        ubyte* buffer;
        ushort num_grays;
        ubyte pixel_mode, palette_mode;
        void* palette;
    }
    struct FT_GlyphSlotRec
    {
        void* library;
        FT_FaceRec* face;
        FT_GlyphSlotRec* next;
        uint glyph_index;
        FT_Generic generic;
        FT_Glyph_Metrics metrics;
        c_long linearHoriAdvance, linearVertAdvance;
        FT_Vector advance;
        uint format;
        FT_Bitmap bitmap;
        int bitmap_left, bitmap_top;
    }
    struct FT_FaceRec
    {
        c_long num_faces, face_index, face_flags, style_flags, num_glyphs;
        char* family_name, style_name;
        int num_fixed_sizes;
        void* available_sizes;
        int num_charmaps;
        void* charmaps;
        FT_Generic generic;
        FT_BBox bbox;
        ushort units_per_EM;
        short ascender, descender, height, max_advance_width, max_advance_height,
            underline_position, underline_thickness;
        FT_GlyphSlotRec* glyph;
    }

    int FT_Init_FreeType(void** library);
    int FT_Done_FreeType(void* library);
    int FT_New_Face(void* library, const(char)* path, c_long index, FT_FaceRec** face);
    int FT_Done_Face(FT_FaceRec* face);
    int FT_Set_Pixel_Sizes(FT_FaceRec* face, uint width, uint height);
    int FT_Load_Glyph(FT_FaceRec* face, uint glyph, int flags);
}

enum FT_LOAD_NO_HINTING = 1 << 1, FT_LOAD_RENDER = 1 << 2, FT_LOAD_NO_BITMAP = 1 << 3;
enum FT_PIXEL_MODE_GRAY = 2;

// ---------------------------------------------------------------------------
// The rasterizer of outline-sink-raster.d, emitting 8-bit coverage.
// ---------------------------------------------------------------------------
struct Rasterizer
{
    int w, h;
    float[] acc;

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
                const xmf = 0.5f * (x + xnext) - xaFloor;
                acc[row + xai] += d - d * xmf;
                acc[row + xai + 1] += d * xmf;
            }
            else
            {
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

    ubyte[] coverage() const @safe pure nothrow
    {
        auto c = new ubyte[w * h];
        foreach (y; 0 .. h)
        {
            float sum = 0;
            foreach (x; 0 .. w)
            {
                sum += acc[y * (w + 2) + x];
                c[y * w + x] = cast(ubyte)(min(abs(sum), 1.0f) * 255 + 0.5f);
            }
        }
        return c;
    }
}

void swap(ref float a, ref float b) @safe pure nothrow @nogc { const t = a; a = b; b = t; }

// ---------------------------------------------------------------------------
// The sink: HarfBuzz outline callbacks, flattened into the rasterizer.
// Input is in 1/64 px (font scale = ppem * 64), y-up.
// ---------------------------------------------------------------------------
struct Sink
{
    Rasterizer* r;
    float ox, oy; // origin in raster pixels, y-down
    float k; // raster pixels per output pixel: 1, or 4 when supersampling
    bool freetypeFlattening;
    float px, py, startX, startY;
    bool drew;

    float sx(float x) const nothrow @nogc => ox + x / 64 * k;
    float sy(float y) const nothrow @nogc => oy - y / 64 * k;

    void lineTo(float x, float y) nothrow @nogc
    {
        r.line(sx(px), sy(py), sx(x), sy(y));
        px = x;
        py = y;
        drew = true;
    }
}

enum tolerancePx = 0.02f; // production flattening tolerance

extern (C) nothrow @nogc void onMove(hb_draw_funcs_t*, void* d, hb_draw_state_t*, float x, float y, void*)
{
    auto s = cast(Sink*) d;
    s.px = s.startX = x;
    s.py = s.startY = y;
}

extern (C) nothrow @nogc void onLine(hb_draw_funcs_t*, void* d, hb_draw_state_t*, float x, float y, void*)
{
    (cast(Sink*) d).lineTo(x, y);
}

extern (C) nothrow @nogc void onQuad(hb_draw_funcs_t*, void* d, hb_draw_state_t*,
    float cx, float cy, float x, float y, void*)
{
    auto s = cast(Sink*) d;
    const x0 = s.px, y0 = s.py;
    int n;
    if (s.freetypeFlattening)
    {
        // ftgrays.c gray_render_conic: each bisection quarters the deviation.
        float dev = max(abs(x0 + x - 2 * cx), abs(y0 + y - 2 * cy)) / 64 * s.k;
        n = 1;
        if (dev >= 0.25f)
            do { dev /= 4; n *= 2; } while (dev > 0.25f);
    }
    else // a quadratic's chord deviates by |p0 - 2c + p2| / (8 n^2)
        n = max(1, cast(int) ceil(sqrt(hypot(x0 - 2 * cx + x, y0 - 2 * cy + y) / 64 / 8 / tolerancePx)));
    foreach (i; 1 .. n + 1)
    {
        const t = float(i) / n, u = 1 - t;
        s.lineTo(u * u * x0 + 2 * u * t * cx + t * t * x, u * u * y0 + 2 * u * t * cy + t * t * y);
    }
}

extern (C) nothrow @nogc void onCubic(hb_draw_funcs_t*, void* d, hb_draw_state_t*,
    float c1x, float c1y, float c2x, float c2y, float x, float y, void*)
{
    auto s = cast(Sink*) d;
    const x0 = s.px, y0 = s.py;
    if (s.freetypeFlattening)
    {
        // ftgrays.c gray_render_cubic: bisect until the control points lie
        // within half a pixel of the trisection test.
        const limit = 0.5f * 64 / s.k;
        void split(float[8] a, int depth)
        {
            if (depth < 16
                && (abs(2 * a[0] - 3 * a[2] + a[6]) > limit || abs(2 * a[1] - 3 * a[3] + a[7]) > limit
                || abs(a[0] - 3 * a[4] + 2 * a[6]) > limit || abs(a[1] - 3 * a[5] + 2 * a[7]) > limit))
            {
                const m01x = (a[0] + a[2]) / 2, m01y = (a[1] + a[3]) / 2;
                const m12x = (a[2] + a[4]) / 2, m12y = (a[3] + a[5]) / 2;
                const m23x = (a[4] + a[6]) / 2, m23y = (a[5] + a[7]) / 2;
                const ax = (m01x + m12x) / 2, ay = (m01y + m12y) / 2;
                const bx = (m12x + m23x) / 2, by = (m12y + m23y) / 2;
                const mx = (ax + bx) / 2, my = (ay + by) / 2;
                split([a[0], a[1], m01x, m01y, ax, ay, mx, my], depth + 1);
                split([mx, my, bx, by, m23x, m23y, a[6], a[7]], depth + 1);
            }
            else
                s.lineTo(a[6], a[7]);
        }
        split([x0, y0, c1x, c1y, c2x, c2y, x, y], 0);
        return;
    }
    // A cubic's chord deviates by at most 3/4 of its largest second difference / n^2.
    const dd = max(hypot(x0 - 2 * c1x + c2x, y0 - 2 * c1y + c2y), hypot(c1x - 2 * c2x + x, c1y - 2 * c2y + y));
    const n = max(1, cast(int) ceil(sqrt(dd * 0.75f / 64 / tolerancePx)));
    foreach (i; 1 .. n + 1)
    {
        const t = float(i) / n, u = 1 - t;
        s.lineTo(u * u * u * x0 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x,
            u * u * u * y0 + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y);
    }
}

extern (C) nothrow @nogc void onClose(hb_draw_funcs_t*, void* d, hb_draw_state_t*, void*)
{
    auto s = cast(Sink*) d;
    if (s.px != s.startX || s.py != s.startY)
        s.lineTo(s.startX, s.startY);
}

// ---------------------------------------------------------------------------

/// Per glyph, whether `glyf` sets OVERLAP_SIMPLE or OVERLAP_COMPOUND.
/// Empty for a face without `glyf` (CFF), which has no such flag.
bool[] overlapFlags(const(ubyte)[] d) @safe pure
{
    uint u16(size_t o) => o + 2 <= d.length ? (d[o] << 8) | d[o + 1] : 0;
    uint u32(size_t o) => o + 4 <= d.length
        ? (uint(d[o]) << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3] : 0;
    size_t head, loca, glyf, maxp;
    foreach (i; 0 .. u16(4))
    {
        const r = 12 + i * 16, off = u32(r + 8);
        switch (cast(const(char)[]) d[r .. r + 4])
        {
            case "head": head = off; break;
            case "loca": loca = off; break;
            case "glyf": glyf = off; break;
            case "maxp": maxp = off; break;
            default: break;
        }
    }
    if (!glyf || !loca || !head || !maxp)
        return null;
    const longOffsets = u16(head + 50) == 1;
    size_t offset(size_t g) => glyf + (longOffsets ? u32(loca + g * 4) : u16(loca + g * 2) * 2);
    auto flags = new bool[u16(maxp + 4)];
    foreach (g, ref flag; flags)
    {
        const start = offset(g);
        if (offset(g + 1) <= start)
            continue;
        const contours = cast(short) u16(start);
        if (contours > 0)
        {
            const instructions = start + 10 + contours * 2;
            const firstFlag = instructions + 2 + u16(instructions);
            flag = firstFlag < d.length && (d[firstFlag] & 0x40) != 0;
        }
        else if (contours < 0)
            for (size_t p = start + 10;;)
            {
                const f = u16(p);
                if (f & 0x0400)
                {
                    flag = true;
                    break;
                }
                if (!(f & 0x20)) // MORE_COMPONENTS
                    break;
                p += 4 + ((f & 1) ? 4 : 2) + ((f & 8) ? 2 : (f & 0x40) ? 4 : (f & 0x80) ? 8 : 0);
            }
    }
    return flags;
}

ubyte percentile(const(ubyte)[] sorted, double p) @safe pure nothrow @nogc
    => sorted.length ? sorted[min(sorted.length - 1, cast(size_t)(p / 100 * sorted.length))] : 0;

/// One face at one size in one configuration: per-pixel differences over
/// pixels either side inks, and each glyph's largest difference.
void compare(FT_FaceRec* ft, hb_font_t* font, hb_draw_funcs_t* funcs, const(bool)[] overlap,
    uint glyphs, int ppem, bool freetypeFlattening)
{
    enum margin = 4;
    hb_font_set_scale(font, ppem * 64, ppem * 64);
    FT_Set_Pixel_Sizes(ft, 0, ppem);
    ubyte[] pixels, glyphMax;
    foreach (gid; 0 .. glyphs)
    {
        if (FT_Load_Glyph(ft, gid, FT_LOAD_NO_HINTING | FT_LOAD_RENDER | FT_LOAD_NO_BITMAP) != 0)
            continue;
        const bm = ft.glyph.bitmap;
        if (bm.pixel_mode != FT_PIXEL_MODE_GRAY)
            continue;
        const w = bm.width + 2 * margin, h = bm.rows + 2 * margin;
        const ss = gid < overlap.length && overlap[gid] ? 4 : 1;
        auto r = new Rasterizer(w * ss, h * ss);
        auto sink = Sink(r, ss * (margin - ft.glyph.bitmap_left), ss * (margin + ft.glyph.bitmap_top),
            ss, freetypeFlattening);
        hb_font_draw_glyph(font, gid, funcs, &sink);
        if (!sink.drew && bm.width == 0)
            continue;
        const fine = r.coverage();
        ubyte ours(size_t x, size_t y)
        {
            uint sum;
            foreach (j; 0 .. ss)
                foreach (i; 0 .. ss)
                    sum += fine[(y * ss + j) * w * ss + x * ss + i];
            return cast(ubyte)((sum + ss * ss / 2) / (ss * ss));
        }
        ubyte worst;
        foreach (y; 0 .. h)
            foreach (x; 0 .. w)
            {
                const fx = x - margin, fy = y - margin;
                const int theirs = fx >= 0 && fy >= 0 && fx < bm.width && fy < bm.rows
                    ? bm.buffer[fy * bm.pitch + fx] : 0;
                const int mine = ours(x, y);
                if (!theirs && !mine)
                    continue;
                const diff = cast(ubyte) abs(mine - theirs);
                pixels ~= diff;
                worst = max(worst, diff);
            }
        glyphMax ~= worst;
    }
    pixels.sort();
    glyphMax.sort();
    writefln("  %-11s %2d px  %6d glyphs  pixel p50 %3d  p99 %3d  max %3d  glyph max p50 %3d  p99 %3d  ≤16: %5.1f%%",
        freetypeFlattening ? "ft-flatten" : "production", ppem, glyphMax.length,
        pixels.percentile(50), pixels.percentile(99), pixels.length ? pixels[$ - 1] : 0,
        glyphMax.percentile(50), glyphMax.percentile(99),
        100.0 * glyphMax.count!(m => m <= 16) / max(1, glyphMax.length));
}

void measure(void* library, hb_draw_funcs_t* funcs, string path)
{
    auto blob = hb_blob_create_from_file(path.toStringz);
    scope (exit) hb_blob_destroy(blob);
    if (hb_blob_get_length(blob) == 0)
    {
        writeln("SKIP: empty blob for ", path);
        return;
    }
    auto face = hb_face_create(blob, 0);
    scope (exit) hb_face_destroy(face);
    auto font = hb_font_create(face);
    scope (exit) hb_font_destroy(font);
    FT_FaceRec* ft;
    if (FT_New_Face(library, path.toStringz, 0, &ft) != 0)
    {
        writeln("SKIP: FreeType cannot open ", path);
        return;
    }
    scope (exit) FT_Done_Face(ft);

    const glyphs = hb_face_get_glyph_count(face);
    // The declared FreeType layout must agree with HarfBuzz before any pixel counts.
    if (ft.units_per_EM != hb_face_get_upem(face) || ft.num_glyphs != glyphs || ft.glyph.face != ft)
    {
        writeln("FAIL: FT_FaceRec layout disagrees with HarfBuzz for ", path);
        return;
    }
    const overlap = overlapFlags(cast(const(ubyte)[]) read(path));
    writefln("%s: %d glyphs, upem %d, %d flagged overlapping", path.baseName, glyphs,
        ft.units_per_EM, overlap.count(true));
    foreach (freetypeFlattening; [false, true])
        foreach (ppem; [12, 16, 24, 48])
            compare(ft, font, funcs, overlap, glyphs, ppem, freetypeFlattening);
}

string[] resolveFonts(string[] args)
{
    string[] given;
    foreach (a; args[1 .. $])
        if (exists(a))
            given ~= a;
    if (given.length)
        return given;
    try
    {
        auto r = execute(["fc-match", "-f", "%{file}", "monospace"]);
        if (r.status == 0 && r.output.strip.length && exists(r.output.strip))
            return [r.output.strip];
    }
    catch (Exception) {}
    return null;
}

int main(string[] args)
{
    const fonts = resolveFonts(args);
    if (!fonts.length)
    {
        writeln("SKIP: no font file resolved (pass paths, or install fontconfig)");
        return 0;
    }
    void* library;
    if (FT_Init_FreeType(&library) != 0)
    {
        writeln("SKIP: FreeType failed to initialize");
        return 0;
    }
    scope (exit) FT_Done_FreeType(library);
    auto funcs = hb_draw_funcs_create();
    scope (exit) hb_draw_funcs_destroy(funcs);
    hb_draw_funcs_set_move_to_func(funcs, &onMove, null, null);
    hb_draw_funcs_set_line_to_func(funcs, &onLine, null, null);
    hb_draw_funcs_set_quadratic_to_func(funcs, &onQuad, null, null);
    hb_draw_funcs_set_cubic_to_func(funcs, &onCubic, null, null);
    hb_draw_funcs_set_close_path_func(funcs, &onClose, null, null);
    foreach (path; fonts)
        measure(library, funcs, path);
    return 0;
}
