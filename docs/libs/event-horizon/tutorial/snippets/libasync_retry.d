#!/usr/bin/env dub
/+ dub.sdl:
    name "libasync_retry"
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
    int failures, value;
    auto timer = new AsyncTimer(evl);
    timer.periodic().duration(10.msecs).run({
        ticks++;
        auto error = tryOperation(ticks, value);
        if (error) { assert(error == 11); ++failures; return; }
        if (ticks == 3) writeln("succeeded on attempt ", ticks);
        if (ticks >= 3)
            timer.kill();
    });

    while (ticks < 3)
        evl.loop();

    assert(ticks == 3);
    assert(failures == 2 && value == 42);
}

int tryOperation(int attempt, out int value) @safe nothrow
{
    if (attempt < 3) return 11; // deterministic Linux EAGAIN injection
    value = 42;
    return 0;
}
