/**
The HarfBuzz functions the oracle calls, hand-declared over opaque handles.

The structs that cross (`hb_ot_name_entry_t` and the `MATH` records) have
their layouts checked against the C definitions by tests (FTA8's rule for
every struct the font stack reads).
*/
module sparkles.font_oracle.harfbuzz;

extern (C) nothrow @nogc:

struct hb_blob_t;
struct hb_face_t;
struct hb_font_t;
struct hb_set_t;
struct hb_language_impl_t;

alias hb_codepoint_t = uint;
alias hb_bool_t = int;
alias hb_language_t = const(hb_language_impl_t)*;

enum hb_memory_mode_t : int
{
    HB_MEMORY_MODE_DUPLICATE,
    HB_MEMORY_MODE_READONLY,
}

/// `hb_ot_name_entry_t`: a name ID, a private 32-bit field, a language.
struct hb_ot_name_entry_t
{
    uint name_id;
    uint var;
    hb_language_t language;
}

enum hb_codepoint_t HB_SET_VALUE_INVALID = uint.max;

hb_blob_t* hb_blob_create(const(char)* data, uint length, hb_memory_mode_t mode, void* user_data,
    void* destroy);
void hb_blob_destroy(hb_blob_t* blob);
uint hb_face_count(hb_blob_t* blob);
hb_face_t* hb_face_create(hb_blob_t* blob, uint index);
void hb_face_destroy(hb_face_t* face);
uint hb_face_get_upem(const(hb_face_t)* face);
uint hb_face_get_glyph_count(const(hb_face_t)* face);
void hb_face_collect_unicodes(hb_face_t* face, hb_set_t* out_);
hb_font_t* hb_font_create(hb_face_t* face);
void hb_font_destroy(hb_font_t* font);
hb_bool_t hb_font_get_nominal_glyph(hb_font_t* font, hb_codepoint_t unicode, hb_codepoint_t* glyph);
hb_bool_t hb_font_get_glyph_name(hb_font_t* font, hb_codepoint_t glyph, char* name, uint size);
int hb_font_get_glyph_h_advance(hb_font_t* font, hb_codepoint_t glyph);
hb_set_t* hb_set_create();
void hb_set_destroy(hb_set_t* set);
hb_bool_t hb_set_next(const(hb_set_t)* set, hb_codepoint_t* codepoint);
const(hb_ot_name_entry_t)* hb_ot_name_list_names(hb_face_t* face, uint* num_entries);
uint hb_ot_name_get_utf8(hb_face_t* face, uint name_id, hb_language_t language, uint* text_size, char* text);

// M2: variations, metrics, vertical metrics, layout, colour, MATH and BASE.

alias hb_tag_t = uint;
alias hb_position_t = int;

/// `HB_OT_LAYOUT_DEFAULT_LANGUAGE_INDEX`: a script's default language system.
enum uint HB_OT_LAYOUT_DEFAULT_LANGUAGE_INDEX = 0xFFFF;

/// `hb_direction_t`'s horizontal and vertical forward directions.
enum hb_direction_t : int
{
    HB_DIRECTION_INVALID = 0,
    HB_DIRECTION_LTR = 4,
    HB_DIRECTION_RTL,
    HB_DIRECTION_TTB,
    HB_DIRECTION_BTT,
}

/// `hb_ot_metrics_tag_t`: the `MVAR` value tags, as big-endian integers.
alias hb_ot_metrics_tag_t = uint;

void hb_font_set_scale(hb_font_t* font, int x_scale, int y_scale);
void hb_font_set_var_coords_normalized(hb_font_t* font, const(int)* coords, uint coords_length);
int hb_font_get_glyph_v_advance(hb_font_t* font, hb_codepoint_t glyph);
hb_bool_t hb_font_get_glyph_v_origin(hb_font_t* font, hb_codepoint_t glyph, hb_position_t* x,
    hb_position_t* y);
void hb_set_add(hb_set_t* set, hb_codepoint_t codepoint);
uint hb_set_get_population(const(hb_set_t)* set);
hb_bool_t hb_set_is_equal(const(hb_set_t)* set, const(hb_set_t)* other);
hb_bool_t hb_set_is_subset(const(hb_set_t)* set, const(hb_set_t)* larger_set);

uint hb_ot_var_get_axis_count(hb_face_t* face);
void hb_ot_var_normalize_coords(hb_face_t* face, uint coords_length, const(float)* design_coords,
    int* normalized_coords);

hb_bool_t hb_ot_metrics_get_position(hb_font_t* font, hb_ot_metrics_tag_t metrics_tag,
    hb_position_t* position);

uint hb_ot_layout_table_get_script_tags(hb_face_t* face, hb_tag_t table_tag, uint start_offset,
    uint* script_count, hb_tag_t* script_tags);
uint hb_ot_layout_table_get_feature_tags(hb_face_t* face, hb_tag_t table_tag, uint start_offset,
    uint* feature_count, hb_tag_t* feature_tags);
uint hb_ot_layout_table_get_lookup_count(hb_face_t* face, hb_tag_t table_tag);
uint hb_ot_layout_script_get_language_tags(hb_face_t* face, hb_tag_t table_tag, uint script_index,
    uint start_offset, uint* language_count, hb_tag_t* language_tags);
uint hb_ot_layout_language_get_feature_indexes(hb_face_t* face, hb_tag_t table_tag, uint script_index,
    uint language_index, uint start_offset, uint* feature_count, uint* feature_indexes);
hb_bool_t hb_ot_layout_language_get_required_feature(hb_face_t* face, hb_tag_t table_tag,
    uint script_index, uint language_index, uint* feature_index, hb_tag_t* feature_tag);
uint hb_ot_layout_feature_get_lookups(hb_face_t* face, hb_tag_t table_tag, uint feature_index,
    uint start_offset, uint* lookup_count, uint* lookup_indexes);
void hb_ot_layout_lookup_collect_glyphs(hb_face_t* face, hb_tag_t table_tag, uint lookup_index,
    hb_set_t* glyphs_before, hb_set_t* glyphs_input, hb_set_t* glyphs_after, hb_set_t* glyphs_output);
hb_bool_t hb_ot_layout_get_baseline(hb_font_t* font, hb_tag_t baseline_tag, hb_direction_t direction,
    hb_tag_t script_tag, hb_tag_t language_tag, hb_position_t* coord);

hb_bool_t hb_ot_color_has_layers(hb_face_t* face);
hb_bool_t hb_ot_color_has_paint(hb_face_t* face);
hb_bool_t hb_ot_color_has_palettes(hb_face_t* face);
hb_bool_t hb_ot_color_has_png(hb_face_t* face);
hb_bool_t hb_ot_color_has_svg(hb_face_t* face);

hb_bool_t hb_ot_math_has_data(hb_face_t* face);

/// `hb_ot_math_glyph_variant_t`: a size variant and its advance.
struct hb_ot_math_glyph_variant_t
{
    hb_codepoint_t glyph;
    hb_position_t advance;
}

/// `hb_ot_math_glyph_part_t`: one assembly part; `flags` is a C enum (an `int`).
struct hb_ot_math_glyph_part_t
{
    hb_codepoint_t glyph;
    hb_position_t start_connector_length;
    hb_position_t end_connector_length;
    hb_position_t full_advance;
    int flags;
}

/// `hb_ot_math_kern_entry_t`: a kern value up to a correction height.
struct hb_ot_math_kern_entry_t
{
    hb_position_t max_correction_height;
    hb_position_t kern_value;
}

hb_position_t hb_ot_math_get_constant(hb_font_t* font, int constant);
hb_position_t hb_ot_math_get_glyph_italics_correction(hb_font_t* font, hb_codepoint_t glyph);
hb_position_t hb_ot_math_get_glyph_top_accent_attachment(hb_font_t* font, hb_codepoint_t glyph);
hb_bool_t hb_ot_math_is_glyph_extended_shape(hb_face_t* face, hb_codepoint_t glyph);
hb_position_t hb_ot_math_get_glyph_kerning(hb_font_t* font, hb_codepoint_t glyph, int kern,
    hb_position_t correction_height);
uint hb_ot_math_get_glyph_kernings(hb_font_t* font, hb_codepoint_t glyph, int kern, uint start_offset,
    uint* entries_count, hb_ot_math_kern_entry_t* kern_entries);
uint hb_ot_math_get_glyph_variants(hb_font_t* font, hb_codepoint_t glyph, hb_direction_t direction,
    uint start_offset, uint* variants_count, hb_ot_math_glyph_variant_t* variants);
hb_position_t hb_ot_math_get_min_connector_overlap(hb_font_t* font, hb_direction_t direction);
uint hb_ot_math_get_glyph_assembly(hb_font_t* font, hb_codepoint_t glyph, hb_direction_t direction,
    uint start_offset, uint* parts_count, hb_ot_math_glyph_part_t* parts, hb_position_t* italics_correction);
