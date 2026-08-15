// The ImportC surface for SDL3.
//
// Three shim concerns, each a real ImportC limitation rather than a
// preference. All were found by compiling, not guessed:
//
//  1. `_FORTIFY_SOURCE`. The nix stdenv's cc wrapper enables it, and glibc's
//     fortified `<string.h>` then expands `memcpy` and friends to
//     `__builtin___memcpy_chk` intrinsics that ImportC does not implement.
//     Turning it off for this translation unit costs nothing: the fortified
//     variants only ever guard SDL's own inline helpers, and the compiled SDL
//     library is unaffected.
//
//  2. `SDL_HAS_BUILTIN`. SDL uses `__builtin_mul_overflow` and
//     `__builtin_add_overflow` where the compiler advertises them. ImportC's
//     preprocessor answers `__has_builtin` truthfully for a compiler back end
//     that does not implement them, so the guard is forced closed and SDL's
//     portable fallbacks are selected instead.
//
//  3. Narrow includes, not `<SDL3/SDL.h>`. The umbrella header pulls in
//     `SDL_bits.h`, whose `SDL_MostSignificantBitIndex32` reaches for
//     `__builtin_clz` behind a bare `#if defined(__GNUC__)` — no
//     `SDL_HAS_BUILTIN` guard to close, and ImportC does define `__GNUC__`.
//     Including only the headers this library binds avoids it entirely, and
//     documents the surface we depend on.
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#define SDL_HAS_BUILTIN(x) 0

// `nothrow @nogc` is accurate: these are C entry points that neither allocate
// through the D GC nor throw D exceptions. `pure` is omitted — SDL calls
// mutate window-system and event-queue state.
#pragma attribute(push, nogc, nothrow)
#include <SDL3/SDL_version.h>
#include <SDL3/SDL_init.h>
#include <SDL3/SDL_video.h>
#include <SDL3/SDL_events.h>
#include <SDL3/SDL_error.h>
#include <SDL3/SDL_clipboard.h>
#include <SDL3/SDL_timer.h>
#include <SDL3/SDL_vulkan.h>
#pragma attribute(pop)
