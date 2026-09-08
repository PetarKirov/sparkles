#!/usr/bin/env dub
/+ dub.sdl:
    name "libasync_concurrency"
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

    int a = 0;
    int b = 0;
    bool doneA = false;
    bool doneB = false;

    // Dispatch slow operation (30ms)
    auto slow = new AsyncTimer(evl);
    slow.duration(30.msecs).run({
        a = 1;
        doneA = true;
        slow.kill();
    });

    // Dispatch fast operation (5ms)
    auto fast = new AsyncTimer(evl);
    fast.duration(5.msecs).run({
        b = 2;
        doneB = true;
        fast.kill();
    });

    // Manual event loop crank until both callbacks complete
    while (!doneA || !doneB)
        evl.loop();

    const joined = a * 10 + b;
    assert(doneA && doneB);
    assert(joined == 12);
    writeln("joined: ", joined);
}
