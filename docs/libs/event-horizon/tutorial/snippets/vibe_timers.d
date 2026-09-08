#!/usr/bin/env dub
/+ dub.sdl:
    name "vibe_timers"
    dependency "vibe-core" version="2.14.0"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.stdio : writeln;
import vibe.core.core : sleep;

void main()
{
    int ticks = 0;
    foreach (i; 1 .. 4)
    {
        sleep(10.msecs); // parks this fiber only
        writeln("tick ", i);
        ++ticks;
    }
    assert(ticks == 3);
}
