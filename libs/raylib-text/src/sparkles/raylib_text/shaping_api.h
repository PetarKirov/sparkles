#ifndef SPARKLES_SHAPING_API_H
#define SPARKLES_SHAPING_API_H
#include <stdint.h>
#pragma attribute(push, nogc, nothrow)

typedef struct STLibrary STLibrary;
typedef struct STFace STFace;
typedef struct STBitmap {
    unsigned char *rgba;
    int width, height, left, top;
    float advance;
    int color, valid;
} STBitmap;

STLibrary *st_library_create(void);
void st_library_destroy(STLibrary *library);
int st_face_count(STLibrary *library, const char *path);
STFace *st_face_open(STLibrary *library, const char *path, int faceIndex, int pixels);
void st_face_close(STFace *face);
int st_face_has(STFace *face, uint32_t cp);
int st_face_is_color(STFace *face);
float st_face_ascent(STFace *face);
void st_bitmap_free(STBitmap *bitmap);
STBitmap st_shape(STFace *face, const uint32_t *cps, unsigned count);
int st_kern_advances(STFace *face, const uint32_t *cps, unsigned count, float *advances);
#pragma attribute(pop)
#endif
