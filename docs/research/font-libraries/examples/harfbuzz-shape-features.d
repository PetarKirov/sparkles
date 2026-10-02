#!/usr/bin/env dub
/+ dub.sdl:
    name "font_libraries_harfbuzz_shape_features"
    targetPath "build"
    libs "harfbuzz"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * HarfBuzz's whole object model in one program, pure D with hand-declared
 * `extern(C)` prototypes — no FreeType, no C shim, no struct of HarfBuzz's is
 * anything but plain data.
 *
 * Demonstrates, against a real font file:
 *
 *   1. The layering `hb_blob_t` → `hb_face_t` → `hb_font_t` → `hb_buffer_t`:
 *      bytes, then the immutable parsed face (`upem`, glyph count), then a
 *      face at a scale, then the mutable shaping buffer. Every object is
 *      reference-counted and opaque; the only structs that cross the boundary
 *      are the glyph info/position records and the feature/variation/axis
 *      descriptors.
 *   2. `hb_ot_layout_table_get_feature_tags` — the feature inventory an
 *      inspector lists (`GSUB` and `GPOS` separately).
 *   3. `hb_ot_var_get_axis_infos` — the `fvar` axes, and
 *      `hb_font_set_variations` setting one before shaping, so the advances a
 *      variable font reports move with the axis.
 *   4. `hb_shape` with an explicit `hb_feature_t[]`: the same string shaped with
 *      `calt`+`liga` forced on and forced off. On a programming font with
 *      contextual ligatures (Maple Mono, Fira Code) the glyph sequence differs;
 *      on a font without them it is identical — both are findings.
 *   5. Output units: `x_advance` is in font units scaled by `hb_font_set_scale`;
 *      here scale = upem so the numbers are design units.
 *
 * Companion to docs/research/font-libraries/harfbuzz.md § Analysis spine 1–4,
 * and the catalog's RQ3/RQ5 (variation flow; inspector inventory).
 *
 * Run with: dub run --single harfbuzz-shape-features.d [-- /path/to/font.ttf]
 *
 * Font resolution: the first argument if given, else `fc-match -f %{file}
 * monospace`. If neither yields a readable file (no fontconfig on the host,
 * e.g. macOS CI), prints a `SKIP:` line and exits 0 so CI stays green.
 */
module font_libraries_harfbuzz_shape_features;

import std.stdio : writeln, writefln;
import std.string : fromStringz, toStringz, strip;
import std.process : execute;
import std.file : exists;

// ---------------------------------------------------------------------------
// HarfBuzz C ABI, the subset this program needs. Layouts follow hb-common.h,
// hb-buffer.h and hb-ot-var.h: every field is a 32-bit scalar.
// ---------------------------------------------------------------------------
extern (C) nothrow @nogc
{

struct hb_blob_t;
struct hb_face_t;
struct hb_font_t;
struct hb_buffer_t;

alias hb_codepoint_t = uint;
alias hb_position_t = int;
alias hb_tag_t = uint;
alias hb_bool_t = int;

struct hb_glyph_info_t
{
    hb_codepoint_t codepoint; // glyph id after shaping
    uint mask;
    uint cluster; // index into the input (UTF-8 byte offset here)
    uint var1, var2; // hb_var_int_t, private
}

struct hb_glyph_position_t
{
    hb_position_t x_advance, y_advance, x_offset, y_offset;
    uint var; // private
}

struct hb_feature_t
{
    hb_tag_t tag;
    uint value;
    uint start, end;
}

struct hb_variation_t
{
    hb_tag_t tag;
    float value;
}

struct hb_ot_var_axis_info_t
{
    uint axis_index;
    hb_tag_t tag;
    uint name_id;
    uint flags;
    float min_value, default_value, max_value;
    uint reserved;
}

hb_blob_t* hb_blob_create_from_file(const(char)* file_name);
void hb_blob_destroy(hb_blob_t*);
uint hb_blob_get_length(hb_blob_t*);

hb_face_t* hb_face_create(hb_blob_t*, uint index);
void hb_face_destroy(hb_face_t*);
uint hb_face_get_upem(const(hb_face_t)*);
uint hb_face_get_glyph_count(const(hb_face_t)*);

hb_font_t* hb_font_create(hb_face_t*);
void hb_font_destroy(hb_font_t*);
void hb_ot_font_set_funcs(hb_font_t*);
void hb_font_set_scale(hb_font_t*, int x_scale, int y_scale);
void hb_font_set_variations(hb_font_t*, const(hb_variation_t)*, uint count);
hb_bool_t hb_font_get_glyph_name(hb_font_t*, hb_codepoint_t glyph, char* name, uint size);

hb_buffer_t* hb_buffer_create();
void hb_buffer_destroy(hb_buffer_t*);
void hb_buffer_add_utf8(hb_buffer_t*, const(char)* text, int text_length,
    uint item_offset, int item_length);
void hb_buffer_guess_segment_properties(hb_buffer_t*);
uint hb_buffer_get_length(const(hb_buffer_t)*);
hb_glyph_info_t* hb_buffer_get_glyph_infos(hb_buffer_t*, uint* length);
hb_glyph_position_t* hb_buffer_get_glyph_positions(hb_buffer_t*, uint* length);

void hb_shape(hb_font_t*, hb_buffer_t*, const(hb_feature_t)* features, uint num_features);

uint hb_ot_layout_table_get_feature_tags(hb_face_t*, hb_tag_t table_tag,
    uint start_offset, uint* feature_count, hb_tag_t* feature_tags);
uint hb_ot_var_get_axis_count(hb_face_t*);
uint hb_ot_var_get_axis_infos(hb_face_t*, uint start_offset, uint* axes_count,
    hb_ot_var_axis_info_t* axes_array);

} // extern (C)

/// `HB_TAG('c','a','l','t')` as a D function: big-endian packed ASCII.
hb_tag_t tag(string s) @safe pure nothrow @nogc
in (s.length == 4)
    => (uint(s[0]) << 24) | (uint(s[1]) << 16) | (uint(s[2]) << 8) | uint(s[3]);

/// The inverse, by value: four characters, no allocation.
char[4] tagName(hb_tag_t t) @safe pure nothrow @nogc
    => [cast(char)(t >> 24), cast(char)(t >> 16), cast(char)(t >> 8), cast(char) t];

string resolveFont(string[] args) @safe
{
    if (args.length > 1 && exists(args[1]))
        return args[1];
    try
    {
        auto r = execute(["fc-match", "-f", "%{file}", "monospace"]);
        if (r.status == 0 && r.output.strip.length && exists(r.output.strip))
            return r.output.strip;
    }
    catch (Exception) {}
    return null;
}

void listFeatures(hb_face_t* face, string table) @trusted
{
    hb_tag_t[64] tags;
    uint count = tags.length;
    hb_ot_layout_table_get_feature_tags(face, tag(table), 0, &count, tags.ptr);
    string line;
    foreach (t; tags[0 .. count])
        line ~= tagName(t)[] ~ " ";
    writefln("%s features (%d): %s", table, count, line);
}

void shape(hb_font_t* font, string text, const(hb_feature_t)[] features, string label) @trusted
{
    auto buf = hb_buffer_create();
    scope (exit) hb_buffer_destroy(buf);
    hb_buffer_add_utf8(buf, text.ptr, cast(int) text.length, 0, cast(int) text.length);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(font, buf, features.ptr, cast(uint) features.length);

    uint n;
    auto infos = hb_buffer_get_glyph_infos(buf, &n);
    auto pos = hb_buffer_get_glyph_positions(buf, &n);
    writefln("  %-14s %d glyphs:", label, n);
    foreach (i; 0 .. n)
    {
        char[64] name;
        if (!hb_font_get_glyph_name(font, infos[i].codepoint, name.ptr, name.length))
            name[0] = 0;
        writefln("    gid %5d  cluster %2d  adv %5d  %s", infos[i].codepoint,
            infos[i].cluster, pos[i].x_advance, fromStringz(name.ptr));
    }
}

int main(string[] args)
{
    const path = resolveFont(args);
    if (path is null)
    {
        writeln("SKIP: no font file resolved (pass a path, or install fontconfig)");
        return 0;
    }

    auto blob = hb_blob_create_from_file(path.toStringz);
    scope (exit) hb_blob_destroy(blob);
    if (hb_blob_get_length(blob) == 0)
    {
        writeln("SKIP: empty blob for ", path);
        return 0;
    }
    auto face = hb_face_create(blob, 0);
    scope (exit) hb_face_destroy(face);
    const upem = hb_face_get_upem(face);
    writefln("font: %s", path);
    writefln("upem %d, %d glyphs, %d variation axes", upem,
        hb_face_get_glyph_count(face), hb_ot_var_get_axis_count(face));

    // (2) inspector inventory
    listFeatures(face, "GSUB");
    listFeatures(face, "GPOS");

    // (3) axes, and a variation set before shaping
    hb_ot_var_axis_info_t[16] axes;
    uint axisCount = axes.length;
    hb_ot_var_get_axis_infos(face, 0, &axisCount, axes.ptr);
    hb_variation_t[1] variations;
    foreach (a; axes[0 .. axisCount])
    {
        writefln("axis %s  min %g  default %g  max %g", tagName(a.tag)[],
            a.min_value, a.default_value, a.max_value);
        if (a.tag == tag("wght"))
            variations[0] = hb_variation_t(a.tag, a.max_value);
    }

    auto font = hb_font_create(face);
    scope (exit) hb_font_destroy(font);
    hb_ot_font_set_funcs(font); // HarfBuzz's own OpenType font functions; no FreeType
    hb_font_set_scale(font, upem, upem); // advances in design units
    if (variations[0].tag != 0)
    {
        hb_font_set_variations(font, variations.ptr, 1);
        writefln("variation set: %s = %g", tagName(variations[0].tag)[], variations[0].value);
    }

    // (4) the same text, contextual ligatures on and off
    const text = "a -> b != c ffi";
    const on = [hb_feature_t(tag("calt"), 1, 0, uint.max), hb_feature_t(tag("liga"), 1, 0, uint.max)];
    const off = [hb_feature_t(tag("calt"), 0, 0, uint.max), hb_feature_t(tag("liga"), 0, 0, uint.max)];
    writefln("shaping %(%s%):", [text]);
    shape(font, text, on, "calt+liga on");
    shape(font, text, off, "calt+liga off");
    return 0;
}
