/*
 * ImportC shim for the Cairo 2D vector library.
 *
 * The file stem becomes the D module name (`cairo_c.c` -> module `cairo_c`),
 * imported as `sparkles.anim_backend.cairo_c`. A UNIQUE stem per C backend is
 * mandatory: two ImportC shims both named `c.c` in one binary collide with
 * "module 'c' conflicts", which matters here because a real engine co-links
 * Cairo + Blend2D + libav + HarfBuzz into a single test/executable.
 *
 * `#pragma attribute(push, nogc, nothrow)` tags every imported declaration so
 * the Cairo calls stay usable from `@nogc nothrow` D code (Cairo neither
 * allocates through the GC nor throws D exceptions).
 */
#pragma attribute(push, nogc, nothrow)
#include <cairo.h>
#pragma attribute(pop)
