/*
 * ImportC translation unit for libsodium.
 *
 * D compiles this `.c` file (it lives under the package `src/` root, which dub
 * scans by default) as an ImportC module named `sparkles.crypto.sodium_c`,
 * exposing every libsodium-exported symbol to D. The preprocessor finds
 * <sodium.h> via the `-P-I$SODIUM_INCLUDE` dflag in dub.sdl, where
 * SODIUM_INCLUDE is exported by the Nix devshell shellHook.
 *
 * ImportC does not expose C macros or `static inline` functions as D symbols.
 * libsodium's public API is entirely exported shared-library symbols, so direct
 * binding works; if a macro constant is ever needed, add a concrete C wrapper
 * function here that returns it.
 */
#include <sodium.h>
