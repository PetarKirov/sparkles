// ImportC shim for utf8proc (JuliaStrings/utf8proc). The file name becomes the
// D module `sparkles.utf8proc.c`.
//
// utf8proc is stateless and table-driven (it reads only immutable Unicode
// tables), so `pure` is honest here — unlike the stateful ghostty bindings. All
// calls are `@nogc nothrow`: they never allocate via the D GC nor throw D
// exceptions (the few that allocate use libc malloc, which is `@nogc`-clean).
// See https://dlang.org/spec/importc#pragma.
#pragma attribute(push, nogc, nothrow, pure)
#include <utf8proc.h>
#pragma attribute(pop)
