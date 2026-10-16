#!/usr/bin/env dub
/+ dub.sdl:
    name "android-research-load-probe"
    platforms "linux"
    dflags "-betterC"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
E3's dependency-free dlopen payload. Build as a shared library for Android;
the default host executable just tests the exported function.
See ../index.md#current-target-experiments.
*/
module load_probe;

/// A symbol to keep the shared-library payload nonempty.
extern(C) export int sparkles_load_probe() @safe pure nothrow @nogc => 42;

version (LoadProbeLibrary) {} else
    extern(C) int main() @safe pure nothrow @nogc => sparkles_load_probe() == 42 ? 0 : 1;
