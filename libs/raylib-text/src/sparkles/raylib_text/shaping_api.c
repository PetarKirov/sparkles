// Keep FreeType/HarfBuzz headers out of dependent static-library builds:
// dub supplies their pkg-config flags only for executable/sourceLibrary builds.
#pragma attribute(push, nogc, nothrow)
#include "shaping_api.h"
#pragma attribute(pop)
