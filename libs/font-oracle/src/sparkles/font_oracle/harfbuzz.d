/**
The HarfBuzz functions the oracle calls, hand-declared over opaque handles.

Only `hb_ot_name_entry_t` crosses as a struct; its layout is checked
against the C definition's size by a test (FTA8's rule for every struct the
font stack reads).
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
