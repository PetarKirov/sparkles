#!/usr/bin/env dub
/+ dub.sdl:
    name "photon_deadline"
    dependency "photon" version="0.19.3"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs, seconds;
import std.stdio : writeln;
import photon;

// In Photon, Task.interrupt() is a no-op and there is no runtime cancellation tree.
// Timeouts must be manually handled using synchronization primitives like Condition.wait(dur).
void main()
{
    initPhoton();

    bool timedOut;
    bool cleanedUp;

    go({
        auto mtx = mutex();
        auto cond = condition();
        string sleepResult;

        mtx.lock();
        // A manual timeout wrapper around a long wait:
        // Photon's cond.wait(mtx, dur) returns false on timeout.
        const success = cond.wait(mtx, 50.msecs);
        if (!success)
        {
            sleepResult = "stopped by adapter";
            timedOut = true;
        }
        else
        {
            sleepResult = "ok";
        }
        mtx.unlock();

        writeln("sleep returned: ", sleepResult);
        assert(sleepResult == "stopped by adapter");

        // Photon has no protect!() primitive; cleanup must be explicitly scheduled
        delay(5.msecs);
        cleanedUp = true;

        assert(timedOut);
        assert(cleanedUp);
        writeln("timed out: ", timedOut);
        writeln("cleaned up: ", cleanedUp);
        mtx.dispose();
    });

    runScheduler();
    assert(timedOut && cleanedUp);
}
