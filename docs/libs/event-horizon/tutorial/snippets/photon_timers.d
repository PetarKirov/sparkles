#!/usr/bin/env dub
/+ dub.sdl:
    name "photon_timers"
    dependency "photon" version="0.19.3"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.stdio : writeln;
import photon;

void main()
{
    initPhoton();

    int ticks;
    go({
        foreach (i; 1 .. 4)
        {
            // delay() or standard Thread.sleep() via libc interception
            delay(10.msecs);
            writeln("tick ", i);
            ++ticks;
        }
    });

    runScheduler();
    assert(ticks == 3);
}
