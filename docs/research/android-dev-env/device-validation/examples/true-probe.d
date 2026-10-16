#!/usr/bin/env dub
/+ dub.sdl:
    name "android-research-true-probe"
    platforms "linux"
    dflags "-betterC"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/** E7's silent, identical Bionic payload for all three process-start routes.
See ../index.md#current-target-experiments. */
module true_probe;

extern(C) int main() @safe pure nothrow @nogc => 0;
