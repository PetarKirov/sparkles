#!/usr/bin/env dub
/+ dub.sdl:
    name "build_mode_probe"
    dependency "sparkles:base" path="../../.."
    targetPath "build"

    // The build this repo ships nix artifacts with: optimised, assertions
    // live, `debug {}` blocks out. Neither `debug` (which turns those blocks
    // on) nor `release` (which deletes every assert expression).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Reports what the build mode it was compiled with actually does — whether
 * `assert` expressions survive, whether `debug {}` blocks are compiled in,
 * and whether `-preview` flags from the manifest still reached the compiler.
 *
 * The three properties are independent, and the interesting combinations are
 * not the ones the build-type names suggest:
 *
 * ```
 * dub run --single build-mode-probe.d --build=debug     # asserts on,  debug blocks ON
 * dub run --single build-mode-probe.d --build=release   # asserts OFF, debug blocks off
 * dub run --single build-mode-probe.d --build=checked   # asserts on,  debug blocks off
 * ```
 *
 * `release` deleting the *expression* — not just the check — is the property
 * worth remembering: a call written inside an assert does not happen.
 */
module build_mode_probe;

import std.stdio : writefln, writeln;

/// Set from inside an `assert` expression. If assertions are compiled out the
/// whole expression goes with them, so this stays false — the same mechanism
/// that silently skipped a `connect()` written inside an assert.
bool sideEffectRan;

bool markAndPass()
{
    sideEffectRan = true;
    return true;
}

int main()
{
    assert(markAndPass());

    bool debugBlockRan;
    debug debugBlockRan = true;

    writefln("assert expressions live : %s", sideEffectRan);
    writefln("debug {} blocks compiled: %s", debugBlockRan);
    writeln();

    if (!sideEffectRan)
        writeln("=> -release: assertions (and any side effect inside one) are GONE");
    else if (debugBlockRan)
        writeln("=> -debug: assertions live, but debug blocks add their cost too");
    else
        writeln("=> checked: assertions live, debug blocks out — the shipping build");

    return 0;
}
