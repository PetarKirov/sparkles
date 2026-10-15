// HarfBuzz's public API for the oracle, parsed by ImportC from the installed
// headers, so every declaration and struct layout is the library's own.
//
// Shared system types stay outside the attribute scope (see
// docs/guidelines/importc-c-libraries.md); HarfBuzz itself is stateful, so its
// declarations are `nothrow @nogc` but not `pure`.
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#include <stdint.h>

#pragma attribute(push, nogc, nothrow)
#include <hb.h>
#include <hb-ot.h>
#pragma attribute(pop)
