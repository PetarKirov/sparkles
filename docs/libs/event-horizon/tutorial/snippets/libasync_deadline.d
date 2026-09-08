#!/usr/bin/env dub
/+ dub.sdl:
    name "libasync_deadline"
    dependency "libasync" version="0.9.8"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs, seconds;
import std.stdio : writeln;
import libasync;

void main()
{
    auto evl = new EventLoop;
    scope (exit) { evl.exit(); evl.destroy(); }

    bool timedOut = false;
    bool cleanedUp = false;
    bool cancelled = false;

    // The long-running operation (10s)
    auto slow = new AsyncTimer(evl);
    slow.duration(10.seconds).run({
        assert(false, "Should not fire");
    });

    // Cleanup timer (simulating protected cleanup)
    AsyncTimer cleanupTimer;

    // The deadline timer (50ms)
    auto deadline = new AsyncTimer(evl);
    deadline.duration(50.msecs).run({
        timedOut = true;
        // In libasync, cancellation is manual: kill the pending timer
        slow.kill();
        cancelled = true;
        writeln("sleep returned: ", cancelled ? "stopped by adapter" : "ok");

        // Protected cleanup must be manually scheduled and tracked
        cleanupTimer = new AsyncTimer(evl);
        cleanupTimer.duration(5.msecs).run({
            cleanedUp = true;
            cleanupTimer.kill();
        });
        deadline.kill();
    });

    while (!cleanedUp)
        evl.loop();

    assert(timedOut);
    assert(cleanedUp);
    writeln("timed out: ", timedOut);
    writeln("cleaned up: ", cleanedUp);
}
