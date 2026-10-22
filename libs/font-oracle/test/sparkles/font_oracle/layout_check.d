/**
The FTA8/FTS6 layout check: the hand-declared HarfBuzz structs of
`sparkles:font`'s engine configuration against the installed `hb.h`,
parsed here by ImportC, so the declaration is the library's own.
*/
module sparkles.font_oracle.layout_check;

import hbdecl = sparkles.font.harfbuzz;
import sparkles.font_oracle;

/// The blob mode must preserve borrowed, potentially read-only font bytes.
@("oracle.layout.hbMemoryMode")
@safe pure nothrow @nogc
unittest
{
    assert(hbdecl.HB_MEMORY_MODE_READONLY == HB_MEMORY_MODE_READONLY);
}

@("oracle.layout.hbStructs")
@safe pure nothrow @nogc
unittest
{
    static assert(hbdecl.hb_glyph_info_t.sizeof == hb_glyph_info_t.sizeof);
    static assert(hbdecl.hb_glyph_info_t.codepoint.offsetof == hb_glyph_info_t.codepoint.offsetof);
    static assert(hbdecl.hb_glyph_info_t.mask.offsetof == hb_glyph_info_t.mask.offsetof);
    static assert(hbdecl.hb_glyph_info_t.cluster.offsetof == hb_glyph_info_t.cluster.offsetof);

    static assert(hbdecl.hb_glyph_position_t.sizeof == hb_glyph_position_t.sizeof);
    static assert(hbdecl.hb_glyph_position_t.x_advance.offsetof
        == hb_glyph_position_t.x_advance.offsetof);
    static assert(hbdecl.hb_glyph_position_t.y_advance.offsetof
        == hb_glyph_position_t.y_advance.offsetof);
    static assert(hbdecl.hb_glyph_position_t.x_offset.offsetof
        == hb_glyph_position_t.x_offset.offsetof);
    static assert(hbdecl.hb_glyph_position_t.y_offset.offsetof
        == hb_glyph_position_t.y_offset.offsetof);

    static assert(hbdecl.hb_feature_t.sizeof == hb_feature_t.sizeof);
    static assert(hbdecl.hb_feature_t.tag.offsetof == hb_feature_t.tag.offsetof);
    static assert(hbdecl.hb_feature_t.value.offsetof == hb_feature_t.value.offsetof);
    static assert(hbdecl.hb_feature_t.start.offsetof == hb_feature_t.start.offsetof);
    static assert(hbdecl.hb_feature_t.end.offsetof == hb_feature_t.end.offsetof);

    static assert(hbdecl.hb_variation_t.sizeof == hb_variation_t.sizeof);
    static assert(hbdecl.hb_variation_t.tag.offsetof == hb_variation_t.tag.offsetof);
    static assert(hbdecl.hb_variation_t.value.offsetof == hb_variation_t.value.offsetof);

    static assert(hbdecl.hb_ot_var_axis_info_t.sizeof == hb_ot_var_axis_info_t.sizeof);
    static assert(hbdecl.hb_ot_var_axis_info_t.axis_index.offsetof
        == hb_ot_var_axis_info_t.axis_index.offsetof);
    static assert(hbdecl.hb_ot_var_axis_info_t.tag.offsetof
        == hb_ot_var_axis_info_t.tag.offsetof);
    static assert(hbdecl.hb_ot_var_axis_info_t.name_id.offsetof
        == hb_ot_var_axis_info_t.name_id.offsetof);
    static assert(hbdecl.hb_ot_var_axis_info_t.flags.offsetof
        == hb_ot_var_axis_info_t.flags.offsetof);
    static assert(hbdecl.hb_ot_var_axis_info_t.min_value.offsetof
        == hb_ot_var_axis_info_t.min_value.offsetof);
    static assert(hbdecl.hb_ot_var_axis_info_t.default_value.offsetof
        == hb_ot_var_axis_info_t.default_value.offsetof);
    static assert(hbdecl.hb_ot_var_axis_info_t.max_value.offsetof
        == hb_ot_var_axis_info_t.max_value.offsetof);
}
