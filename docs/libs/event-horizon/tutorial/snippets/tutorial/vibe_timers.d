#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_vibe_timers"
    dependency "vibe-core" version="2.14.0"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs;
import std.stdio : writeln;
import vibe.core.core : sleep;

void main() @system
{
    foreach (tick; 1 .. 4) { sleep(10.msecs); writeln("tick ", tick); }
}
