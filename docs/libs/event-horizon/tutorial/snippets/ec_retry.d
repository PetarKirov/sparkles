#!/usr/bin/env dub
/+ dub.sdl:
    name "ec_retry"
    dependency "eventcore" version="0.9.39"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : Duration, msecs;
import eventcore.core;
import std.stdio : writeln;

void main()
{
    int count = 0;
    int failures, value;
    auto tm = eventDriver.timers.create();
    assert(eventDriver.timers.isValid(tm));

    void onTimer(TimerID id) nothrow @safe
    {
        count++;
        auto error = tryOperation(count, value);
        if (error) { assert(error == 11); ++failures; }
        try if (count == 3) writeln("succeeded on attempt ", count);
        catch (Exception error) { assert(false, error.msg); }

        // eventcore's wait() only triggers once; re-arm for periodic ticks:
        if (error)
        {
            eventDriver.timers.wait(id, &onTimer);
        }
        else
        {
            eventDriver.timers.stop(id);
            eventDriver.timers.releaseRef(id);
        }
    }

    eventDriver.timers.set(tm, 10.msecs, 10.msecs);
    eventDriver.timers.wait(tm, &onTimer);

    while (eventDriver.core.waiterCount > 0)
        eventDriver.core.processEvents(Duration.max);

    assert(count == 3);
    assert(failures == 2 && value == 42);
}

int tryOperation(int attempt, out int value) @safe nothrow
{
    if (attempt < 3) return 11; // deterministic Linux EAGAIN injection
    value = 42;
    return 0;
}
