// Compile the shared mode constructor once; D imports the declarations in c.c.
#include "c.c"

#pragma attribute(push, nogc, nothrow)
GhosttyMode ghostty_mode_new(uint16_t value, bool ansi) {
    return sparkles_ghostty_mode_new_impl(value, ansi);
}
#pragma attribute(pop)
