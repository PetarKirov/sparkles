// Keep shared system callback types unannotated across ImportC modules.
#include <stdint.h>

// Mark every libghostty-vt declaration `nothrow @nogc` on the D side. The C
// functions neither allocate via the D GC nor throw D exceptions, so this is
// accurate — and it lets callers stay in `@nogc nothrow` code without casting
// the function pointers. `pure` is deliberately omitted: these calls mutate
// terminal state. See https://dlang.org/spec/importc#pragma.
#pragma attribute(push, nogc, nothrow)
// The mode macros call this header-only static inline helper. DMD cannot
// reference a C static from an importing D module, so keep the upstream body
// private and expose an externally linked entry point with the public name.
// Macro replacement lists expand at use, so GHOSTTY_MODE_* use the public
// wrapper after the rename is undone.
#define ghostty_mode_new sparkles_ghostty_mode_new_impl
#include <ghostty/vt.h>
#undef ghostty_mode_new

// Defined in ghostty_modes.c, which dub emits as a source rather than an
// import-only declaration module.
GhosttyMode ghostty_mode_new(uint16_t value, bool ansi);
#pragma attribute(pop)
