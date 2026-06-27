// ImportC shim for notcurses' ncstrwidth — scoped to the text-conformance
// harness. File stem `notcurses_c` ⇒ module `notcurses_c` (unique stem).
//
// We deliberately do NOT `#include <notcurses/notcurses.h>`: it pulls in glibc's
// fortified `<wchar.h>`, whose inline wrappers use `__builtin_dynamic_object_size`
// — a builtin LDC's ImportC preprocessor doesn't implement (the nix cc wrapper
// forces `_FORTIFY_SOURCE`, so it can't be disabled from here). `ncstrwidth`'s
// signature is pure primitives, so we declare just its prototype; the symbol
// resolves from `libnotcurses-core` at link time (declaration-only, like the
// utf8proc shim). See the ImportC guideline.
//
// `int ncstrwidth(const char* egcs, int* validbytes, int* validwidth)` returns
// the number of columns the (grapheme-aware) EGC string occupies.
#pragma attribute(push, nogc, nothrow)
int ncstrwidth(const char* egcs, int* validbytes, int* validwidth);
#pragma attribute(pop)
