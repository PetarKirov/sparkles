#!/usr/bin/env dub
/+ dub.sdl:
    name "collie_concurrency"
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

    int a = 0;
    int b = 0;
    int doneCount = 0;

    // Slow task (30 ms)
    Timer slowTimer = new Timer(loop, 30.msecs);
    slowTimer.onTick((Object) {
        slowTimer.stop();
        a = 1;
        ++doneCount;
        if (doneCount == 2)
            loop.stop();
    });
    slowTimer.start(false, true);

    // Fast task (5 ms)
    Timer fastTimer = new Timer(loop, 5.msecs);
    fastTimer.onTick((Object) {
        fastTimer.stop();
        b = 2;
        ++doneCount;
        if (doneCount == 2)
            loop.stop();
    });
    fastTimer.start(false, true);

    loop.run();

    const joined = a * 10 + b;
    assert(joined == 12);
    writeln("joined: ", joined);
}
