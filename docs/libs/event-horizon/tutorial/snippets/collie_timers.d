#!/usr/bin/env dub
/+ dub.sdl:
    name "collie_timers"
    dependency "collie" path=".deps/collie"
    dependency "kiss" path=".deps/kiss"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.stdio : writeln;
import kiss.event;
import kiss.util.timer;

void main()
{
    auto loop = new EventLoop();
    scope(exit) loop.dispose();
    int ticks = 0;

    Timer timer = new Timer(loop, 10.msecs);
    timer.onTick((Object sender) {
        ++ticks;
        writeln("tick ", ticks);
        if (ticks >= 3)
        {
            timer.stop();
            loop.stop();
        }
    });
    timer.start();
    loop.run();

    assert(ticks == 3);
}
