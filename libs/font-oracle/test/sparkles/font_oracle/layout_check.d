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

/// The constants the engine passes or reads equal `hb.h`'s.
@("oracle.layout.hbConstants")
@safe pure nothrow @nogc
unittest
{
    static assert(hbdecl.hb_ot_var_axis_info_t.reserved.offsetof
        == hb_ot_var_axis_info_t.reserved.offsetof);

    static assert(hbdecl.HB_BUFFER_FLAG_BOT == HB_BUFFER_FLAG_BOT);
    static assert(hbdecl.HB_BUFFER_FLAG_EOT == HB_BUFFER_FLAG_EOT);
    static assert(hbdecl.HB_BUFFER_FLAG_PRODUCE_UNSAFE_TO_CONCAT == HB_BUFFER_FLAG_PRODUCE_UNSAFE_TO_CONCAT);
    static assert(hbdecl.HB_BUFFER_FLAG_PRODUCE_SAFE_TO_INSERT_TATWEEL
        == HB_BUFFER_FLAG_PRODUCE_SAFE_TO_INSERT_TATWEEL);
    static assert(hbdecl.HB_GLYPH_FLAG_UNSAFE_TO_BREAK == HB_GLYPH_FLAG_UNSAFE_TO_BREAK);
    static assert(hbdecl.HB_GLYPH_FLAG_UNSAFE_TO_CONCAT == HB_GLYPH_FLAG_UNSAFE_TO_CONCAT);
    static assert(hbdecl.HB_GLYPH_FLAG_SAFE_TO_INSERT_TATWEEL == HB_GLYPH_FLAG_SAFE_TO_INSERT_TATWEEL);
    static assert(hbdecl.HB_GLYPH_FLAG_DEFINED == HB_GLYPH_FLAG_DEFINED);

    static assert(cast(int) hbdecl.hb_direction_t.invalid == HB_DIRECTION_INVALID);
    static assert(cast(int) hbdecl.hb_direction_t.ltr == HB_DIRECTION_LTR);
    static assert(cast(int) hbdecl.hb_direction_t.rtl == HB_DIRECTION_RTL);
    static assert(cast(int) hbdecl.hb_direction_t.ttb == HB_DIRECTION_TTB);
    static assert(cast(int) hbdecl.hb_direction_t.btt == HB_DIRECTION_BTT);

    static assert(cast(int) hbdecl.hb_buffer_cluster_level_t.monotoneGraphemes
        == HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
    static assert(cast(int) hbdecl.hb_buffer_cluster_level_t.monotoneCharacters
        == HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
    static assert(cast(int) hbdecl.hb_buffer_cluster_level_t.characters == HB_BUFFER_CLUSTER_LEVEL_CHARACTERS);

    // Every general category, by the C name its D member stands for.
    alias C = hbdecl.hb_unicode_general_category_t;
    static assert(cast(int) C.control == HB_UNICODE_GENERAL_CATEGORY_CONTROL);
    static assert(cast(int) C.format == HB_UNICODE_GENERAL_CATEGORY_FORMAT);
    static assert(cast(int) C.unassigned == HB_UNICODE_GENERAL_CATEGORY_UNASSIGNED);
    static assert(cast(int) C.privateUse == HB_UNICODE_GENERAL_CATEGORY_PRIVATE_USE);
    static assert(cast(int) C.surrogate == HB_UNICODE_GENERAL_CATEGORY_SURROGATE);
    static assert(cast(int) C.lowercaseLetter == HB_UNICODE_GENERAL_CATEGORY_LOWERCASE_LETTER);
    static assert(cast(int) C.modifierLetter == HB_UNICODE_GENERAL_CATEGORY_MODIFIER_LETTER);
    static assert(cast(int) C.otherLetter == HB_UNICODE_GENERAL_CATEGORY_OTHER_LETTER);
    static assert(cast(int) C.titlecaseLetter == HB_UNICODE_GENERAL_CATEGORY_TITLECASE_LETTER);
    static assert(cast(int) C.uppercaseLetter == HB_UNICODE_GENERAL_CATEGORY_UPPERCASE_LETTER);
    static assert(cast(int) C.spacingMark == HB_UNICODE_GENERAL_CATEGORY_SPACING_MARK);
    static assert(cast(int) C.enclosingMark == HB_UNICODE_GENERAL_CATEGORY_ENCLOSING_MARK);
    static assert(cast(int) C.nonSpacingMark == HB_UNICODE_GENERAL_CATEGORY_NON_SPACING_MARK);
    static assert(cast(int) C.decimalNumber == HB_UNICODE_GENERAL_CATEGORY_DECIMAL_NUMBER);
    static assert(cast(int) C.letterNumber == HB_UNICODE_GENERAL_CATEGORY_LETTER_NUMBER);
    static assert(cast(int) C.otherNumber == HB_UNICODE_GENERAL_CATEGORY_OTHER_NUMBER);
    static assert(cast(int) C.connectPunctuation == HB_UNICODE_GENERAL_CATEGORY_CONNECT_PUNCTUATION);
    static assert(cast(int) C.dashPunctuation == HB_UNICODE_GENERAL_CATEGORY_DASH_PUNCTUATION);
    static assert(cast(int) C.closePunctuation == HB_UNICODE_GENERAL_CATEGORY_CLOSE_PUNCTUATION);
    static assert(cast(int) C.finalPunctuation == HB_UNICODE_GENERAL_CATEGORY_FINAL_PUNCTUATION);
    static assert(cast(int) C.initialPunctuation == HB_UNICODE_GENERAL_CATEGORY_INITIAL_PUNCTUATION);
    static assert(cast(int) C.otherPunctuation == HB_UNICODE_GENERAL_CATEGORY_OTHER_PUNCTUATION);
    static assert(cast(int) C.openPunctuation == HB_UNICODE_GENERAL_CATEGORY_OPEN_PUNCTUATION);
    static assert(cast(int) C.currencySymbol == HB_UNICODE_GENERAL_CATEGORY_CURRENCY_SYMBOL);
    static assert(cast(int) C.modifierSymbol == HB_UNICODE_GENERAL_CATEGORY_MODIFIER_SYMBOL);
    static assert(cast(int) C.mathSymbol == HB_UNICODE_GENERAL_CATEGORY_MATH_SYMBOL);
    static assert(cast(int) C.otherSymbol == HB_UNICODE_GENERAL_CATEGORY_OTHER_SYMBOL);
    static assert(cast(int) C.lineSeparator == HB_UNICODE_GENERAL_CATEGORY_LINE_SEPARATOR);
    static assert(cast(int) C.paragraphSeparator == HB_UNICODE_GENERAL_CATEGORY_PARAGRAPH_SEPARATOR);
    static assert(cast(int) C.spaceSeparator == HB_UNICODE_GENERAL_CATEGORY_SPACE_SEPARATOR);
}

/**
Whether two prototypes agree as the C ABI sees them: the same number of
parameters, each of the same size and pointer-ness, and a return of the
same size. The D declarations name their own opaque handle types, so
the types themselves cannot be compared.
*/
private template sameShape(alias ours, alias theirs)
{
    import std.traits : isPointer, Parameters, ReturnType;

    enum sameShape = () {
        alias P = Parameters!ours, Q = Parameters!theirs;
        if (P.length != Q.length || ReturnType!ours.sizeof != ReturnType!theirs.sizeof
            || isPointer!(ReturnType!ours) != isPointer!(ReturnType!theirs))
            return false;
        static foreach (i; 0 .. P.length)
            if (P[i].sizeof != Q[i].sizeof || isPointer!(P[i]) != isPointer!(Q[i]))
                return false;
        return true;
    }();
}

/// Every prototype the engine declares has `hb.h`'s shape (FTS6).
@("oracle.layout.hbPrototypes")
@safe pure nothrow @nogc
unittest
{
    static foreach (name; [
            "hb_blob_create", "hb_blob_destroy", "hb_face_create", "hb_face_destroy",
            "hb_font_create", "hb_font_create_sub_font", "hb_font_destroy", "hb_font_set_scale",
            "hb_font_set_var_coords_normalized", "hb_font_set_funcs", "hb_font_funcs_create",
            "hb_font_funcs_destroy", "hb_font_funcs_make_immutable",
            "hb_font_funcs_set_glyph_h_advance_func", "hb_font_funcs_set_glyph_v_advance_func",
            "hb_font_funcs_set_glyph_v_origin_func", "hb_font_get_glyph_v_advance",
            "hb_font_get_glyph_v_origin", "hb_buffer_create", "hb_buffer_destroy",
            "hb_buffer_add", "hb_buffer_add_codepoints", "hb_buffer_allocation_successful",
            "hb_buffer_set_cluster_level", "hb_buffer_set_flags", "hb_buffer_set_direction",
            "hb_buffer_set_script", "hb_buffer_set_language", "hb_buffer_get_direction",
            "hb_buffer_get_script", "hb_buffer_get_language", "hb_buffer_guess_segment_properties",
            "hb_buffer_set_unicode_funcs", "hb_shape_full", "hb_buffer_get_glyph_infos",
            "hb_buffer_get_glyph_positions", "hb_language_from_string", "hb_language_to_string",
            "hb_version_string", "hb_unicode_funcs_create", "hb_unicode_funcs_destroy",
            "hb_unicode_funcs_make_immutable", "hb_unicode_funcs_set_general_category_func",
            "hb_unicode_funcs_set_combining_class_func", "hb_unicode_funcs_set_mirroring_func",
            "hb_unicode_funcs_set_script_func", "hb_unicode_funcs_set_compose_func",
            "hb_unicode_funcs_set_decompose_func",
        ])
        static assert(sameShape!(__traits(getMember, hbdecl, name), mixin(name)), name);
    // The callback types too, through the setters' parameters.
    import std.traits : Parameters;

    static assert(sameShape!(hbdecl.hb_font_get_glyph_h_advance_func_t,
        Parameters!hb_font_funcs_set_glyph_h_advance_func[1]));
    static assert(sameShape!(hbdecl.hb_font_get_glyph_v_advance_func_t,
        Parameters!hb_font_funcs_set_glyph_v_advance_func[1]));
    static assert(sameShape!(hbdecl.hb_font_get_glyph_v_origin_func_t,
        Parameters!hb_font_funcs_set_glyph_v_origin_func[1]));
    static assert(sameShape!(hbdecl.hb_unicode_decompose_func_t,
        Parameters!hb_unicode_funcs_set_decompose_func[1]));
    static assert(sameShape!(hbdecl.hb_unicode_compose_func_t,
        Parameters!hb_unicode_funcs_set_compose_func[1]));
}
