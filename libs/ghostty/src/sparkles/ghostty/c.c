// Mark every libghostty-vt declaration `nothrow @nogc` on the D side. The C
// functions neither allocate via the D GC nor throw D exceptions, so this is
// accurate — and it lets callers stay in `@nogc nothrow` code without casting
// the function pointers. `pure` is deliberately omitted: these calls mutate
// terminal state. See https://dlang.org/spec/importc#pragma.
#pragma attribute(push, nogc, nothrow)
#include <ghostty/vt.h>
#pragma attribute(pop)
