#!/usr/bin/env dub
/+ dub.sdl:
    name "libasync_timers"
    dependency "libasync" version="0.9.8"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.stdio : writeln;
import libasync;

void main()
{
    auto evl = new EventLoop;
    scope (exit) { evl.exit(); evl.destroy(); }

    int ticks = 0;
    auto timer = new AsyncTimer(evl);
    timer.periodic().duration(10.msecs).run({
        ticks++;
        writeln("tick ", ticks);
        if (ticks >= 3)
            timer.kill();
    });

    while (ticks < 3)
        evl.loop();

    assert(ticks == 3);
}
