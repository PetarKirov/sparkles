#!/usr/bin/env dub
/+ dub.sdl:
    name "vibe_deadline"
    dependency "vibe-core" version="2.14.0"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs, seconds;
import std.stdio : writeln;
import vibe.core.core : runTask, setTimer, sleep, sleepUninterruptible;
import vibe.core.task : InterruptException;

void main()
{
    bool timedOut = false;
    bool cleanedUp = false;

    auto t = runTask(() nothrow {
        try
        {
            sleep(10.seconds);
            try writeln("sleep returned: ok"); catch (Exception error) { assert(false, error.msg); }
        }
        catch (InterruptException)
        {
            try writeln("sleep returned: InterruptException"); catch (Exception error) { assert(false, error.msg); }
            timedOut = true;
            // Cleanup: must use uninterruptible sleep to avoid re-interruption
            sleepUninterruptible(5.msecs);
            cleanedUp = true;
        }
        catch (Exception error) { assert(false, error.msg); }
    });

    // Arm timeout timer
    auto timer = setTimer(50.msecs, () nothrow {
        t.interrupt();
    });
    scope (exit) timer.stop();

    t.join();

    assert(timedOut);
    assert(cleanedUp);
    writeln("timed out: ", timedOut);
    writeln("cleaned up: ", cleanedUp);
}
