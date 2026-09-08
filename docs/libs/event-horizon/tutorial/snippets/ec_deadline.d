#!/usr/bin/env dub
/+ dub.sdl:
    name "ec_deadline"
    dependency "eventcore" version="0.9.39"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : Duration, msecs, seconds;
import eventcore.core;
import std.stdio : writeln;

void main()
{
    bool timedOut = false;
    bool cleanedUp = false;
    bool opCancelled = false;

    auto longOp = eventDriver.timers.create();
    auto deadline = eventDriver.timers.create();

    // Start a 10-second operation
    eventDriver.timers.set(longOp, 10.seconds, 0.msecs);
    eventDriver.timers.wait(longOp, (TimerID tm, bool fired) nothrow @safe {
        if (!fired)
        {
            opCancelled = true;
            try writeln("sleep returned: stopped by adapter");
            catch (Exception error) { assert(false, error.msg); }
        }
        eventDriver.timers.releaseRef(tm);
    });

    // Start a 50ms deadline watchdog timer
    eventDriver.timers.set(deadline, 50.msecs, 0.msecs);
    eventDriver.timers.wait(deadline, (TimerID tm) nothrow @safe {
        timedOut = true;
        // Explicitly cancel the long-running operation:
        eventDriver.timers.stop(longOp);
        eventDriver.timers.releaseRef(tm);

        // Manually run shielded cleanup via an auxiliary timer:
        auto cleanupTm = eventDriver.timers.create();
        eventDriver.timers.set(cleanupTm, 5.msecs, 0.msecs);
        eventDriver.timers.wait(cleanupTm, (TimerID ctm) nothrow @safe {
            cleanedUp = true;
            eventDriver.timers.releaseRef(ctm);
            try {
                writeln("timed out: ", timedOut);
                writeln("cleaned up: ", cleanedUp);
            } catch (Exception error) { assert(false, error.msg); }
        });
    });

    while (eventDriver.core.waiterCount > 0)
        eventDriver.core.processEvents(Duration.max);

    assert(opCancelled);
    assert(timedOut);
    assert(cleanedUp);
}
