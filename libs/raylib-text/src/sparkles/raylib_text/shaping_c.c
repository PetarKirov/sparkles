// Native cluster shaping and raster ownership for the ImportC interface.
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0

// Match shaping_api.h and Ghostty's unannotated system callback types.
#include <stdint.h>

#pragma attribute(push, nogc, nothrow)
#include <stddef.h>
#include <stdlib.h>
#include <limits.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>
#include "shaping_api.h"

struct STLibrary { FT_Library ft; };
struct STFace {
    FT_Face ft;
    hb_font_t *font;
    hb_buffer_t *buffer;
    float scale;
};

STLibrary *st_library_create(void)
{
    STLibrary *library = (STLibrary *)malloc(sizeof(STLibrary));
    if (!library) return NULL;
    if (FT_Init_FreeType(&library->ft)) { free(library); return NULL; }
    return library;
}

void st_library_destroy(STLibrary *library)
{
    if (!library) return;
    FT_Done_FreeType(library->ft);
    free(library);
}

int st_face_count(STLibrary *library, const char *path)
{
    FT_Face face;
    if (!library || !path || FT_New_Face(library->ft, path, -1, &face)) return 0;
    int count = face->num_faces > INT_MAX ? INT_MAX : (int)face->num_faces;
    FT_Done_Face(face);
    return count;
}

void st_face_close(STFace *face)
{
    if (!face) return;
    if (face->buffer) hb_buffer_destroy(face->buffer);
    if (face->font) hb_font_destroy(face->font);
    if (face->ft) FT_Done_Face(face->ft);
    free(face);
}

STFace *st_face_open(STLibrary *library, const char *path, int faceIndex, int pixels)
{
    if (!library || !path || faceIndex < 0 || pixels <= 0 || pixels > 16384) return NULL;
    STFace *face = (STFace *)calloc(1, sizeof(STFace));
    if (!face) return NULL;
    if (FT_New_Face(library->ft, path, faceIndex, &face->ft)) {
        st_face_close(face);
        return NULL;
    }
    face->scale = 1.0f;
    FT_Error error;
    if (FT_IS_SCALABLE(face->ft)) {
        // stb/raylib's font size is ascender minus descender, not an em.
        long span = (long)face->ft->ascender - face->ft->descender;
        FT_F26Dot6 size = (FT_F26Dot6)pixels * 64;
        if (span > 0 && face->ft->units_per_EM)
            size = (FT_F26Dot6)((double)size * face->ft->units_per_EM / span + 0.5);
        error = FT_Set_Char_Size(face->ft, 0, size, 72, 72);
    } else if (face->ft->num_fixed_sizes > 0) {
        int selected = 0;
        long best = LONG_MAX;
        for (int i = 0; i < face->ft->num_fixed_sizes; ++i) {
            long delta = face->ft->available_sizes[i].y_ppem - (long)pixels * 64;
            if (delta < 0) delta = -delta;
            if (delta < best) { best = delta; selected = i; }
        }
        error = FT_Select_Size(face->ft, selected);
        long ppem = face->ft->available_sizes[selected].y_ppem;
        if (ppem <= 0) error = 1;
        else face->scale = (float)pixels * 64.0f / (float)ppem;
    } else error = 1;
    if (error) { st_face_close(face); return NULL; }
    face->font = hb_ft_font_create_referenced(face->ft);
    face->buffer = hb_buffer_create();
    if (!face->font || face->font == hb_font_get_empty() ||
        !face->buffer || !hb_buffer_allocation_successful(face->buffer)) {
        st_face_close(face);
        return NULL;
    }
    hb_ft_font_set_load_flags(face->font, FT_LOAD_DEFAULT | FT_LOAD_COLOR);
    return face;
}

int st_face_has(STFace *face, uint32_t cp)
{
    return face && FT_Get_Char_Index(face->ft, cp) != 0;
}

int st_face_is_color(STFace *face)
{
    return face && FT_HAS_COLOR(face->ft);
}

float st_face_ascent(STFace *face)
{
    if (!face) return 0;
    if (FT_IS_SCALABLE(face->ft))
        return (float)FT_MulFix(face->ft->ascender, face->ft->size->metrics.y_scale)
            / 64.0f * face->scale;
    return (float)face->ft->size->metrics.ascender / 64.0f * face->scale;
}

void st_bitmap_free(STBitmap *bitmap)
{
    if (!bitmap) return;
    free(bitmap->rgba);
    *bitmap = (STBitmap){0};
}

static int st_floor(float n) { int i = (int)n; return i - (n < i); }
static int st_ceil(float n) { int i = (int)n; return i + (n > i); }

static int st_load(STFace *face, unsigned glyph)
{
    if (FT_Load_Glyph(face->ft, glyph, FT_LOAD_DEFAULT | FT_LOAD_COLOR)) return 0;
    if (face->ft->glyph->format != FT_GLYPH_FORMAT_BITMAP &&
        FT_Render_Glyph(face->ft->glyph, FT_RENDER_MODE_NORMAL)) return 0;
    FT_Bitmap *bitmap = &face->ft->glyph->bitmap;
    return !bitmap->width || !bitmap->rows || bitmap->pixel_mode == FT_PIXEL_MODE_BGRA ||
        bitmap->pixel_mode == FT_PIXEL_MODE_GRAY || bitmap->pixel_mode == FT_PIXEL_MODE_MONO;
}

// Accumulate in premultiplied RGBA; convert to straight alpha only at the seam.
static void st_composite(unsigned char *dst, const unsigned char *src)
{
    unsigned inverse = 255 - src[3];
    for (int c = 0; c < 4; ++c)
        dst[c] = (unsigned char)(src[c] + (dst[c] * inverse + 127) / 255);
}

// HarfBuzz can decompose a precomposed character when its nominal glyph is
// absent. Preserve that fallback without building a shape plan for every
// unrelated installed face during a Unicode sweep.
static int st_maps_scalar(STFace *face, hb_unicode_funcs_t *unicode, uint32_t cp)
{
    hb_codepoint_t glyph;
    if (hb_font_get_nominal_glyph(face->font, cp, &glyph)) return 1;
    // HarfBuzz also falls back from nonbreaking hyphen to ordinary hyphen.
    if (cp == 0x2011 && hb_font_get_nominal_glyph(face->font, 0x2010, &glyph))
        return 1;
    hb_codepoint_t a, b;
    if (!hb_unicode_decompose(unicode, cp, &a, &b)) return 0;
    return st_maps_scalar(face, unicode, a) &&
        (!b || st_maps_scalar(face, unicode, b));
}

static int st_requires_nominal_glyph(hb_unicode_funcs_t *unicode, uint32_t cp)
{
    // Leave marks, controls and default-ignorables to HarfBuzz. The four
    // Hangul fillers are default-ignorable letters.
    if (cp == 0x115f || cp == 0x1160 || cp == 0x3164 || cp == 0xffa0) return 0;
    hb_unicode_general_category_t category = hb_unicode_general_category(unicode, cp);
    // Reserved default-ignorables occupy the format-control blocks below.
    // Other unassigned scalars cannot acquire a glyph through shaping.
    if (category == HB_UNICODE_GENERAL_CATEGORY_UNASSIGNED)
        return !((cp >= 0x2000 && cp <= 0x20ff) ||
            (cp >= 0xfff0 && cp <= 0xffff) ||
            (cp >= 0xe0000 && cp <= 0xe0fff));
    // These shapers can synthesize letters or presentation forms beyond
    // canonical decomposition. Marks and multi-scalar clusters also bypass
    // this check, including Indic/Khmer split matras and dotted circles.
    switch (hb_unicode_script(unicode, cp)) {
        case HB_SCRIPT_ARABIC:
        case HB_SCRIPT_SYRIAC:
        case HB_SCRIPT_HEBREW:
        case HB_SCRIPT_THAI:
        case HB_SCRIPT_LAO:
        case HB_SCRIPT_HANGUL:
            return 0;
        default:
            break;
    }
    return (category >= HB_UNICODE_GENERAL_CATEGORY_LOWERCASE_LETTER &&
            category <= HB_UNICODE_GENERAL_CATEGORY_UPPERCASE_LETTER) ||
        (category >= HB_UNICODE_GENERAL_CATEGORY_DECIMAL_NUMBER &&
            category <= HB_UNICODE_GENERAL_CATEGORY_OTHER_NUMBER) ||
        (category >= HB_UNICODE_GENERAL_CATEGORY_CONNECT_PUNCTUATION &&
            category <= HB_UNICODE_GENERAL_CATEGORY_OTHER_SYMBOL);
}

STBitmap st_shape(STFace *face, const uint32_t *cps, size_t count)
{
    STBitmap result = {0};
    // HarfBuzz's bulk input length is signed-int-sized. Reject an unsupported
    // full span before narrowing: never shape a silently truncated prefix.
    if (!face || (!cps && count) || count > INT_MAX) return result;
    hb_unicode_funcs_t *unicode = hb_unicode_funcs_get_default();
    if (count == 1 && st_requires_nominal_glyph(unicode, cps[0]) &&
        !st_maps_scalar(face, unicode, cps[0])) return result;
    hb_buffer_t *buffer = face->buffer;
    hb_buffer_reset(buffer);
    // Keep HarfBuzz's zero-advance invisible placeholders.
    // Removing default ignorables can change following mark offsets: a mark
    // after repeated CGJs drifts left by one font advance per removed glyph.
    hb_buffer_set_flags(buffer, HB_BUFFER_FLAG_DEFAULT);
    hb_buffer_add_codepoints(buffer, cps, (int)count, 0, (int)count);
    hb_buffer_guess_segment_properties(buffer);
    hb_shape(face->font, buffer, NULL, 0);
    if (!hb_buffer_allocation_successful(buffer)) return result;
    unsigned length = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buffer, &length);
    hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, NULL);
    float pen_x = 0, pen_y = 0;
    int min_x = INT_MAX, min_y = INT_MAX, max_x = INT_MIN, max_y = INT_MIN;
    for (unsigned i = 0; i < length; ++i) {
        if (!info[i].codepoint || !st_load(face, info[i].codepoint)) return result;
        FT_GlyphSlot glyph = face->ft->glyph;
        float x = pen_x + positions[i].x_offset / 64.0f + glyph->bitmap_left;
        float y = -pen_y - positions[i].y_offset / 64.0f - glyph->bitmap_top;
        // Bound coordinates before float-to-int conversion and allocation.
        if (x < -1048576 || x > 1048576 || y < -1048576 || y > 1048576 ||
            glyph->bitmap.width > 16384 || glyph->bitmap.rows > 16384) return result;
        if (glyph->bitmap.width && glyph->bitmap.rows) {
            int left = st_floor(x), top = st_floor(y);
            int right = left + (int)glyph->bitmap.width;
            int bottom = top + (int)glyph->bitmap.rows;
            if (left < min_x) min_x = left;
            if (top < min_y) min_y = top;
            if (right > max_x) max_x = right;
            if (bottom > max_y) max_y = bottom;
            if (glyph->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA) result.color = 1;
        }
        pen_x += positions[i].x_advance / 64.0f;
        pen_y += positions[i].y_advance / 64.0f;
    }
    result.advance = pen_x * face->scale;
    if (min_x == INT_MAX) { result.valid = 1; return result; }
    int width = max_x - min_x, height = max_y - min_y;
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384 ||
        (size_t)width * height > 16777216) return (STBitmap){0};
    unsigned char *canvas = (unsigned char *)calloc((size_t)width * height, 4);
    if (!canvas) return (STBitmap){0};
    pen_x = pen_y = 0;
    for (unsigned i = 0; i < length; ++i) {
        // The bounds pass already left the sole glyph in the face's slot.
        if (length != 1 && !st_load(face, info[i].codepoint)) {
            free(canvas);
            return (STBitmap){0};
        }
        FT_GlyphSlot glyph = face->ft->glyph;
        FT_Bitmap *bitmap = &glyph->bitmap;
        int x = st_floor(pen_x + positions[i].x_offset / 64.0f + glyph->bitmap_left) - min_x;
        int y = st_floor(-pen_y - positions[i].y_offset / 64.0f - glyph->bitmap_top) - min_y;
        for (unsigned row = 0; row < bitmap->rows && bitmap->width; ++row) {
            const unsigned char *source = bitmap->buffer + (ptrdiff_t)row * bitmap->pitch;
            for (unsigned col = 0; col < bitmap->width; ++col) {
                unsigned char pixel[4];
                if (bitmap->pixel_mode == FT_PIXEL_MODE_BGRA) {
                    pixel[0] = source[col * 4 + 2]; pixel[1] = source[col * 4 + 1];
                    pixel[2] = source[col * 4]; pixel[3] = source[col * 4 + 3];
                } else {
                    unsigned alpha = bitmap->pixel_mode == FT_PIXEL_MODE_MONO
                        ? ((source[col / 8] & (0x80 >> (col % 8))) ? 255 : 0)
                        : (bitmap->num_grays > 1 ? source[col] * 255u / (bitmap->num_grays - 1) : 0);
                    pixel[0] = pixel[1] = pixel[2] = pixel[3] = (unsigned char)alpha;
                }
                st_composite(canvas + ((size_t)(y + row) * width + x + col) * 4, pixel);
            }
        }
        pen_x += positions[i].x_advance / 64.0f;
        pen_y += positions[i].y_advance / 64.0f;
    }
    if (min_x * face->scale < -1048576 || max_x * face->scale > 1048576 ||
        min_y * face->scale < -1048576 || max_y * face->scale > 1048576) {
        free(canvas);
        return (STBitmap){0};
    }
    result.left = st_floor(min_x * face->scale);
    int top = st_floor(min_y * face->scale);
    result.top = -top;
    result.width = st_ceil(max_x * face->scale) - result.left;
    result.height = st_ceil(max_y * face->scale) - top;
    if (result.width <= 0 || result.height <= 0 || result.width > 16384 ||
        result.height > 16384 || (size_t)result.width * result.height > 16777216) {
        free(canvas);
        return (STBitmap){0};
    }
    if (face->scale == 1.0f) result.rgba = canvas;
    else {
        result.rgba = (unsigned char *)calloc((size_t)result.width * result.height, 4);
        if (!result.rgba) { free(canvas); return (STBitmap){0}; }
        // Bilinear filtering in premultiplied space avoids colored edge halos.
        for (int y = 0; y < result.height; ++y) {
            float sy = (top + y + 0.5f) / face->scale - min_y - 0.5f;
            int iy = st_floor(sy);
            float fy = sy - iy;
            for (int x = 0; x < result.width; ++x) {
                float sx = (result.left + x + 0.5f) / face->scale - min_x - 0.5f;
                int ix = st_floor(sx);
                float fx = sx - ix;
                float values[4] = {0};
                for (int dy = 0; dy < 2; ++dy) for (int dx = 0; dx < 2; ++dx) {
                    int px = ix + dx, py = iy + dy;
                    if (px < 0 || px >= width || py < 0 || py >= height) continue;
                    float weight = (dx ? fx : 1 - fx) * (dy ? fy : 1 - fy);
                    const unsigned char *pixel = canvas + ((size_t)py * width + px) * 4;
                    for (int c = 0; c < 4; ++c) values[c] += pixel[c] * weight;
                }
                unsigned char *out = result.rgba + ((size_t)y * result.width + x) * 4;
                for (int c = 0; c < 4; ++c) out[c] = (unsigned char)(values[c] + 0.5f);
            }
        }
        free(canvas);
    }
    size_t area = (size_t)result.width * result.height;
    for (size_t i = 0; i < area; ++i) {
        unsigned char *pixel = result.rgba + i * 4;
        unsigned alpha = pixel[3];
        for (int c = 0; c < 3; ++c) {
            unsigned straight = alpha ? (pixel[c] * 255u + alpha / 2) / alpha : 0;
            pixel[c] = (unsigned char)(straight > 255 ? 255 : straight);
        }
    }
    result.valid = 1;
    return result;
}
#pragma attribute(pop)
