#!/usr/bin/env dub
/+ dub.sdl:
    name "font_libraries_ligature_cells"
    targetPath "build"
    libs "harfbuzz"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Do programming-font ligatures fit a cell grid? Shapes 160 ligature
 * sequences, the union of the Fira Code, JetBrains Mono, Cascadia Code and
 * Maple Mono inventories, each as `a<seq>b`, with `calt`+`liga` on and off,
 * and reports per face:
 *
 *   1. how many sequences shape differently with the features on;
 *   2. how many change the glyph count — a ligature that merges characters
 *      into fewer glyphs would need multi-cell glyph placement in a terminal;
 *   3. how many produce an advance other than the cell (the advance of `0`);
 *   4. how many draw ink outside a glyph's own cell, and the worst reach in
 *      cells — a renderer that clips each glyph to its cell cuts these.
 *
 * Spike S3 of docs/specs/font/PLAN.md; decision FTX7 in
 * docs/specs/font/decisions.md records the result.
 *
 * Run with: dub run --single ligature-cells.d [-- font.ttf ...]
 *
 * Font resolution: the arguments if given, else `fc-match -f %{file}
 * monospace`. If neither yields a readable file, prints a `SKIP:` line and
 * exits 0 so CI stays green.
 */
module font_libraries_ligature_cells;

import std.algorithm : equal, filter, map, max;
import std.array : array;
import std.file : exists;
import std.path : baseName;
import std.process : execute;
import std.stdio : writefln, writeln;
import std.string : strip, toStringz;
import std.utf : count;

// ---------------------------------------------------------------------------
// HarfBuzz C ABI, the subset this program needs. Layouts follow hb-common.h,
// hb-buffer.h and hb-font.h: every field is a 32-bit scalar.
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
    uint cluster;
    uint var1, var2; // private
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

struct hb_glyph_extents_t
{
    hb_position_t x_bearing, y_bearing, width, height;
}

hb_blob_t* hb_blob_create_from_file(const(char)* file_name);
void hb_blob_destroy(hb_blob_t*);
uint hb_blob_get_length(hb_blob_t*);

hb_face_t* hb_face_create(hb_blob_t*, uint index);
void hb_face_destroy(hb_face_t*);
uint hb_face_get_upem(const(hb_face_t)*);

hb_font_t* hb_font_create(hb_face_t*);
void hb_font_destroy(hb_font_t*);
void hb_ot_font_set_funcs(hb_font_t*);
void hb_font_set_scale(hb_font_t*, int x_scale, int y_scale);
hb_bool_t hb_font_get_glyph_extents(hb_font_t*, hb_codepoint_t glyph, hb_glyph_extents_t* extents);

hb_buffer_t* hb_buffer_create();
void hb_buffer_destroy(hb_buffer_t*);
void hb_buffer_add_utf8(hb_buffer_t*, const(char)* text, int text_length,
    uint item_offset, int item_length);
void hb_buffer_guess_segment_properties(hb_buffer_t*);
hb_glyph_info_t* hb_buffer_get_glyph_infos(hb_buffer_t*, uint* length);
hb_glyph_position_t* hb_buffer_get_glyph_positions(hb_buffer_t*, uint* length);

void hb_shape(hb_font_t*, hb_buffer_t*, const(hb_feature_t)* features, uint num_features);

} // extern (C)

/// `HB_TAG('c','a','l','t')` as a D function: big-endian packed ASCII.
hb_tag_t tag(string s) @safe pure nothrow @nogc
in (s.length == 4)
    => (uint(s[0]) << 24) | (uint(s[1]) << 16) | (uint(s[2]) << 8) | uint(s[3]);

/// The union of four fonts' ligature inventories, plus Latin `liga` pairs.
immutable string[] corpus = [
    "->", "-->", "<-", "<--", "<->", "=>", "==>", "<=", ">=", "<=>", "<==>",
    "!=", "!==", "==", "===", "=/=", "/=", "&&", "||", "|||", "::", ":::",
    ":=", "::=", "=:", "?:", "?.", "??", "?=", "!!", "..", "...", "..<", "..=",
    ".=", ".-", ".?", "++", "+++", "--", "---", "**", "***", "//", "///", "/*",
    "*/", "/**", "<!--", "<!---", "|>", "<|", "<|>", "||>", "<||", "|=", "|-",
    "-|", "~>", "<~", "~~", "~~>", "~-", "-~", "~@", "<<", "<<<", ">>", ">>>",
    "<<=", ">>=", ">>-", "-<<", "<*", "*>", "<*>", "<$", "$>", "<$>", "<+",
    "+>", "<+>", "</", "/>", "</>", "#{", "#[", "#(", "#?", "#!", "#_", "#_(",
    "#:", "#=", "##", "###", "####", "]#", "{|", "|}", "[|", "|]", "%%", "^=",
    "=<<", ">=>", "<=<", "=!=", "<<-", "->>", "=>>", "<<~", "~~~", ";;", ";;;",
    "__", "___", "0x", "0xFF", "1x2", "www", "ff", "fi", "fl", "ffi", "ffl",
    "Fl", "Tl", "Il", `\\`, `\n`, "[INFO]", "[ERROR]", "[TODO]", "todo))",
    "fixme))", ">-", "-<", "<:", ":>", "<:<", ">:", ":<", "=~", "!~", "|||>",
    "<|||", "<!", "!>", "&=", "%=", "$(", "@_", "_|_", "-->>", "=>=", "<===",
    "===>", "<-<", ">->",
];

struct Shaped
{
    hb_glyph_info_t[] infos;
    hb_glyph_position_t[] positions;
}

Shaped shape(hb_font_t* font, string text, const(hb_feature_t)[] features) @trusted
{
    auto buf = hb_buffer_create();
    scope (exit) hb_buffer_destroy(buf);
    hb_buffer_add_utf8(buf, text.ptr, cast(int) text.length, 0, cast(int) text.length);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(font, buf, features.ptr, cast(uint) features.length);
    uint n;
    auto infos = hb_buffer_get_glyph_infos(buf, &n)[0 .. n].dup;
    auto positions = hb_buffer_get_glyph_positions(buf, &n)[0 .. n].dup;
    return Shaped(infos, positions);
}

/// How far, in font units, a glyph's ink reaches outside `[0, cell)`.
int spill(hb_font_t* font, hb_glyph_info_t info, hb_glyph_position_t pos, int cell) @trusted
{
    hb_glyph_extents_t e;
    if (!hb_font_get_glyph_extents(font, info.codepoint, &e) || e.width == 0)
        return 0;
    const left = pos.x_offset + e.x_bearing;
    return max(0, -left, left + e.width - cell);
}

void measure(string path) @trusted
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
    hb_ot_font_set_funcs(font);
    const upem = hb_face_get_upem(face);
    hb_font_set_scale(font, upem, upem); // design units

    const cell = shape(font, "0", null).positions[0].x_advance;
    const on = [hb_feature_t(tag("calt"), 1, 0, uint.max), hb_feature_t(tag("liga"), 1, 0, uint.max)];
    const off = [hb_feature_t(tag("calt"), 0, 0, uint.max), hb_feature_t(tag("liga"), 0, 0, uint.max)];

    size_t changed, countChanged, offGrid, spilled;
    int worst;
    string worstSeq;
    foreach (seq; corpus)
    {
        const text = "a" ~ seq ~ "b";
        const a = shape(font, text, on), b = shape(font, text, off);
        if (a.infos.length != text.count)
            ++countChanged;
        if (a.positions.map!(p => p.x_advance).filter!(x => x != cell).array.length)
            ++offGrid;
        if (equal(a.infos.map!(i => i.codepoint), b.infos.map!(i => i.codepoint)))
            continue;
        ++changed;
        int reach;
        foreach (i, info; a.infos)
            reach = max(reach, spill(font, info, a.positions[i], cell));
        if (reach > 0)
            ++spilled;
        if (reach > worst)
        {
            worst = reach;
            worstSeq = seq;
        }
    }
    writefln("%s: upem %d, cell %d", path.baseName, upem, cell);
    writefln("  %d of %d sequences shape differently; %d change the glyph count; "
        ~ "%d have an off-cell advance", changed, corpus.length, countChanged, offGrid);
    writefln("  %d draw ink outside a glyph's own cell; worst reach %.2f cells (%s)",
        spilled, double(worst) / cell, worstSeq);
}

string[] resolveFonts(string[] args) @safe
{
    auto given = args[1 .. $].filter!exists.array;
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
    foreach (path; fonts)
        measure(path);
    return 0;
}
