// ImportC shim for the Nix C API. Compiling this file turns every Nix C
// declaration into a callable D symbol in module `sparkles.nix.c` — the same
// pattern as `libs/ghostty`. See docs/guidelines/importc-c-libraries.md.
//
// The whole public C surface is pulled in: `nix_api_flake.h` transitively
// includes fetchers/store/util/expr, and value/external/main are included
// explicitly. Include guards dedupe the overlap.
//
// Attributes: the Nix C API is *stateful* (it mutates global settings, opens
// stores, and drives a garbage collector), so `pure` is deliberately omitted.
// `nothrow @nogc` is accurate: these C functions neither throw D exceptions
// (they report errors through a `nix_c_context`) nor allocate via the D GC
// (Nix uses its own Boehm GC, which `@nogc` does not govern). Stamping the
// attributes here lets D callers stay in `@nogc nothrow` code without casting
// function pointers. See https://dlang.org/spec/importc#pragma.
#pragma attribute(push, nogc, nothrow)
#include <nix_api_util.h>
#include <nix_api_main.h>
#include <nix_api_store.h>
#include <nix_api_value.h>
#include <nix_api_external.h>
#include <nix_api_expr.h>
#include <nix_api_fetchers.h>
#include <nix_api_flake.h>
#pragma attribute(pop)
