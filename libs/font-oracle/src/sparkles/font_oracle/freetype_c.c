// FreeType's public API for the raster oracle, parsed by ImportC from the
// installed headers, so every declaration is the library's own.
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#include <stdint.h>

#pragma attribute(push, nogc, nothrow)
#include <ft2build.h>
#include FT_FREETYPE_H
#pragma attribute(pop)
