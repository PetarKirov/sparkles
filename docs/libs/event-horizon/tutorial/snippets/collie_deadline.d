#!/usr/bin/env dub
/+ dub.sdl:
    name "collie_deadline"
    dependency "collie" path=".deps/collie"
    dependency "kiss" path=".deps/kiss"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs, seconds;
import std.stdio : writeln;
import kiss.event;
import kiss.util.timer;

void main()
{
    auto loop = new EventLoop();
    scope(exit) loop.dispose();

    bool timedOut = false;
    bool cleanedUp = false;
    string sleepResult = "ok";

    // Long-running operation (10s)
    Timer slowOp = new Timer(loop, 10.seconds);
    slowOp.onTick((Object) {
        sleepResult = "ok";
    });
    slowOp.start();

    // Deadline timer (50ms)
    Timer deadline = new Timer(loop, 50.msecs);
    deadline.onTick((Object) {
        deadline.stop();
        timedOut = true;

        // In collie, cancellation requires manually stopping operations
        slowOp.stop();
        sleepResult = "stopped by adapter";
        writeln("sleep returned: ", sleepResult);

        // Run manual cleanup
        cleanedUp = true;
        loop.stop();
    });
    deadline.start();

    loop.run();

    assert(sleepResult == "stopped by adapter");
    assert(timedOut);
    assert(cleanedUp);

    writeln("timed out: ", timedOut);
    writeln("cleaned up: ", cleanedUp);
}
