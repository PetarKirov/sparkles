#!/usr/bin/env dub
/+ dub.sdl:
    name "ec_timers"
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
    auto tm = eventDriver.timers.create();
    assert(eventDriver.timers.isValid(tm));

    void onTimer(TimerID id) nothrow @safe
    {
        count++;
        try writeln("tick ", count);
        catch (Exception error) { assert(false, error.msg); }

        // eventcore's wait() only triggers once; re-arm for periodic ticks:
        if (count < 3)
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
}
