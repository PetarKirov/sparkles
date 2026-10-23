/**
Hand-declared HarfBuzz C ABI for the `engine` configuration (FTA8, FTS6).

Only opaque handles cross the boundary; the few structs whose fields the
library reads, the constants it passes and the prototypes it calls are
declared here and checked against the installed `hb.h` by
`sparkles:font-oracle`'s layout test. No C source is compiled.
Declarations follow HarfBuzz 14.6.0 headers.

The prototypes are `@system`: they take raw pointers and lengths, and
HarfBuzz keeps global state (interned languages, the locale), so none is
`pure`. Callers wrap each call in the narrowest `@trusted` scope.
*/
module sparkles.font.harfbuzz;

alias hb_bool_t = int;
alias hb_codepoint_t = uint;
alias hb_tag_t = uint;
alias hb_position_t = int;
alias hb_mask_t = uint;

struct hb_blob_t;
struct hb_face_t;
struct hb_font_t;
struct hb_font_funcs_t;
struct hb_buffer_t;
struct hb_unicode_funcs_t;
struct hb_language_impl_t;
alias hb_language_t = const(hb_language_impl_t)*;

/// `hb_glyph_info_t`: glyph ID, mask (glyph flags in the low bits), cluster.
struct hb_glyph_info_t
{
    hb_codepoint_t codepoint;
    hb_mask_t mask;
    uint cluster;
    private uint var1, var2;
}

/// `hb_glyph_position_t`: advances and offsets from the pen position.
struct hb_glyph_position_t
{
    hb_position_t x_advance, y_advance, x_offset, y_offset;
    private uint var;
}

/// `hb_feature_t`: a feature and the cluster range it applies to.
struct hb_feature_t
{
    hb_tag_t tag;
    uint value;
    uint start, end;
}

/// `hb_variation_t`: an axis tag and its user-space value.
struct hb_variation_t
{
    hb_tag_t tag;
    float value;
}

/// `hb_ot_var_axis_info_t`.
struct hb_ot_var_axis_info_t
{
    uint axis_index;
    hb_tag_t tag;
    uint name_id;
    uint flags;
    float min_value, default_value, max_value;
    uint reserved;
}

/// `hb_direction_t`.
enum hb_direction_t : int
{
    invalid = 0,
    ltr = 4,
    rtl = 5,
    ttb = 6,
    btt = 7,
}

/// `hb_buffer_flags_t` values used by shaping.
enum uint HB_BUFFER_FLAG_BOT = 0x01;
/// ditto
enum uint HB_BUFFER_FLAG_EOT = 0x02;
/// ditto
enum uint HB_BUFFER_FLAG_PRODUCE_UNSAFE_TO_CONCAT = 0x40;
/// ditto
enum uint HB_BUFFER_FLAG_PRODUCE_SAFE_TO_INSERT_TATWEEL = 0x80;

/// `hb_glyph_flags_t` values (the low bits of a glyph's mask).
enum uint HB_GLYPH_FLAG_UNSAFE_TO_BREAK = 0x01;
/// ditto
enum uint HB_GLYPH_FLAG_UNSAFE_TO_CONCAT = 0x02;
/// ditto
enum uint HB_GLYPH_FLAG_SAFE_TO_INSERT_TATWEEL = 0x04;
/// ditto
enum uint HB_GLYPH_FLAG_DEFINED = 0x07;

/// `hb_buffer_cluster_level_t`: monotone character clusters (FTS4).
enum hb_buffer_cluster_level_t : int
{
    monotoneGraphemes = 0,
    monotoneCharacters = 1,
    characters = 2,
}

/// `hb_unicode_general_category_t`.
enum hb_unicode_general_category_t : int
{
    control = 0,
    format = 1,
    unassigned = 2,
    privateUse = 3,
    surrogate = 4,
    lowercaseLetter = 5,
    modifierLetter = 6,
    otherLetter = 7,
    titlecaseLetter = 8,
    uppercaseLetter = 9,
    spacingMark = 10,
    enclosingMark = 11,
    nonSpacingMark = 12,
    decimalNumber = 13,
    letterNumber = 14,
    otherNumber = 15,
    connectPunctuation = 16,
    dashPunctuation = 17,
    closePunctuation = 18,
    finalPunctuation = 19,
    initialPunctuation = 20,
    otherPunctuation = 21,
    openPunctuation = 22,
    currencySymbol = 23,
    modifierSymbol = 24,
    mathSymbol = 25,
    otherSymbol = 26,
    lineSeparator = 27,
    paragraphSeparator = 28,
    spaceSeparator = 29,
}

/// `HB_MEMORY_MODE_READONLY`: the blob borrows the caller's bytes.
enum int HB_MEMORY_MODE_READONLY = 1;

/// `hb_destroy_func_t`.
alias hb_destroy_func_t = extern (C) void function(void*) nothrow @nogc;
/// `hb_font_get_glyph_h_advance_func_t`.
alias hb_font_get_glyph_h_advance_func_t = extern (C) hb_position_t function(hb_font_t* font,
    void* fontData, hb_codepoint_t glyph, void* userData) nothrow @nogc;
/// `hb_unicode_general_category_func_t`.
alias hb_unicode_general_category_func_t = extern (C) hb_unicode_general_category_t function(
    hb_unicode_funcs_t*, hb_codepoint_t, void*) nothrow @nogc;
/// `hb_unicode_combining_class_func_t` (the class as an `int` enum).
alias hb_unicode_combining_class_func_t = extern (C) uint function(hb_unicode_funcs_t*,
    hb_codepoint_t, void*) nothrow @nogc;
/// `hb_unicode_mirroring_func_t`.
alias hb_unicode_mirroring_func_t = extern (C) hb_codepoint_t function(hb_unicode_funcs_t*,
    hb_codepoint_t, void*) nothrow @nogc;
/// `hb_unicode_script_func_t`.
alias hb_unicode_script_func_t = extern (C) hb_tag_t function(hb_unicode_funcs_t*,
    hb_codepoint_t, void*) nothrow @nogc;
/// `hb_unicode_compose_func_t`.
alias hb_unicode_compose_func_t = extern (C) hb_bool_t function(hb_unicode_funcs_t*,
    hb_codepoint_t, hb_codepoint_t, hb_codepoint_t*, void*) nothrow @nogc;
/// `hb_unicode_decompose_func_t`.
alias hb_unicode_decompose_func_t = extern (C) hb_bool_t function(hb_unicode_funcs_t*,
    hb_codepoint_t, hb_codepoint_t*, hb_codepoint_t*, void*) nothrow @nogc;

extern (C) @system nothrow @nogc
{
    // Blob, face and font lifecycle.
    hb_blob_t* hb_blob_create(const(char)* data, uint length, int memoryMode,
        void* userData, hb_destroy_func_t destroy);
    void hb_blob_destroy(hb_blob_t* blob);
    hb_face_t* hb_face_create(hb_blob_t* blob, uint index);
    void hb_face_destroy(hb_face_t* face);
    hb_font_t* hb_font_create(hb_face_t* face);
    hb_font_t* hb_font_create_sub_font(hb_font_t* parent);
    void hb_font_destroy(hb_font_t* font);
    void hb_font_set_scale(hb_font_t* font, int xScale, int yScale);
    void hb_font_set_var_coords_normalized(hb_font_t* font, const(int)* coords, uint length);
    void hb_font_set_funcs(hb_font_t* font, hb_font_funcs_t* klass, void* fontData,
        hb_destroy_func_t destroy);

    // Font functions: the library's own advances (FTS1).
    hb_font_funcs_t* hb_font_funcs_create();
    void hb_font_funcs_destroy(hb_font_funcs_t* ffuncs);
    void hb_font_funcs_make_immutable(hb_font_funcs_t* ffuncs);
    void hb_font_funcs_set_glyph_h_advance_func(hb_font_funcs_t* ffuncs,
        hb_font_get_glyph_h_advance_func_t func, void* userData, hb_destroy_func_t destroy);

    // Buffers and shaping.
    hb_buffer_t* hb_buffer_create();
    void hb_buffer_destroy(hb_buffer_t* buffer);
    void hb_buffer_add(hb_buffer_t* buffer, hb_codepoint_t codepoint, uint cluster);
    void hb_buffer_add_codepoints(hb_buffer_t* buffer, const(hb_codepoint_t)* text,
        int textLength, uint itemOffset, int itemLength);
    hb_bool_t hb_buffer_allocation_successful(hb_buffer_t* buffer);
    void hb_buffer_set_cluster_level(hb_buffer_t* buffer, hb_buffer_cluster_level_t level);
    void hb_buffer_set_flags(hb_buffer_t* buffer, uint flags);
    void hb_buffer_set_direction(hb_buffer_t* buffer, hb_direction_t direction);
    void hb_buffer_set_script(hb_buffer_t* buffer, hb_tag_t script);
    void hb_buffer_set_language(hb_buffer_t* buffer, hb_language_t language);
    hb_direction_t hb_buffer_get_direction(hb_buffer_t* buffer);
    hb_tag_t hb_buffer_get_script(hb_buffer_t* buffer);
    hb_language_t hb_buffer_get_language(hb_buffer_t* buffer);
    void hb_buffer_guess_segment_properties(hb_buffer_t* buffer);
    void hb_buffer_set_unicode_funcs(hb_buffer_t* buffer, hb_unicode_funcs_t* funcs);
    hb_bool_t hb_shape_full(hb_font_t* font, hb_buffer_t* buffer,
        const(hb_feature_t)* features, uint numFeatures, const(char*)* shaperList);
    hb_glyph_info_t* hb_buffer_get_glyph_infos(hb_buffer_t* buffer, uint* length);
    hb_glyph_position_t* hb_buffer_get_glyph_positions(hb_buffer_t* buffer, uint* length);

    // Languages and versions.
    hb_language_t hb_language_from_string(const(char)* str, int len);
    const(char)* hb_language_to_string(hb_language_t language);
    const(char)* hb_version_string();

    // Unicode callbacks, all supplied from sparkles:base (FTS8).
    hb_unicode_funcs_t* hb_unicode_funcs_create(hb_unicode_funcs_t* parent);
    void hb_unicode_funcs_destroy(hb_unicode_funcs_t* funcs);
    void hb_unicode_funcs_make_immutable(hb_unicode_funcs_t* funcs);
    void hb_unicode_funcs_set_general_category_func(hb_unicode_funcs_t* funcs,
        hb_unicode_general_category_func_t func, void* userData, hb_destroy_func_t destroy);
    void hb_unicode_funcs_set_combining_class_func(hb_unicode_funcs_t* funcs,
        hb_unicode_combining_class_func_t func, void* userData, hb_destroy_func_t destroy);
    void hb_unicode_funcs_set_mirroring_func(hb_unicode_funcs_t* funcs,
        hb_unicode_mirroring_func_t func, void* userData, hb_destroy_func_t destroy);
    void hb_unicode_funcs_set_script_func(hb_unicode_funcs_t* funcs,
        hb_unicode_script_func_t func, void* userData, hb_destroy_func_t destroy);
    void hb_unicode_funcs_set_compose_func(hb_unicode_funcs_t* funcs,
        hb_unicode_compose_func_t func, void* userData, hb_destroy_func_t destroy);
    void hb_unicode_funcs_set_decompose_func(hb_unicode_funcs_t* funcs,
        hb_unicode_decompose_func_t func, void* userData, hb_destroy_func_t destroy);
}
