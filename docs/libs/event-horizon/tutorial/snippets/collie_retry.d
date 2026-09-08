#!/usr/bin/env dub
/+ dub.sdl:
    name "collie_retry"
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
    int failures, value;

    Timer timer = new Timer(loop, 10.msecs);
    timer.onTick((Object sender) {
        ++ticks;
        auto error = tryOperation(ticks, value);
        if (error) { assert(error == 11); ++failures; return; }
        if (ticks == 3) writeln("succeeded on attempt ", ticks);
        if (ticks >= 3)
        {
            timer.stop();
            loop.stop();
        }
    });
    timer.start();
    loop.run();

    assert(ticks == 3);
    assert(failures == 2 && value == 42);
}

// Deterministic dependency failure: EAGAIN twice, then a value. The timer
// supplies fixed-interval backoff; production code also needs a retry budget.
int tryOperation(int attempt, out int value) @safe nothrow
{
    if (attempt < 3) return 11; // EAGAIN on the Linux fixture platform
    value = 42;
    return 0;
}
