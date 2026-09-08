#!/usr/bin/env dub
/+ dub.sdl:
    name "ec_concurrency"
    dependency "eventcore" version="0.9.39"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : Duration, msecs;
import eventcore.core;
import std.stdio : writeln;

struct JoinState
{
    int slowVal = 0;
    int fastVal = 0;
    int completed = 0;
    bool done = false;
}

void main()
{
    JoinState state;

    void checkDone() nothrow @safe
    {
        if (state.completed == 2)
        {
            state.done = true;
            const result = state.slowVal * 10 + state.fastVal;
            assert(result == 12);
            try writeln("joined: ", result);
            catch (Exception error) { assert(false, error.msg); }
        }
    }

    // Launch slow branch (30ms -> 1)
    auto tmSlow = eventDriver.timers.create();
    eventDriver.timers.set(tmSlow, 30.msecs, 0.msecs);
    eventDriver.timers.wait(tmSlow, (TimerID tm) nothrow @safe {
        state.slowVal = 1;
        state.completed++;
        eventDriver.timers.releaseRef(tm);
        checkDone();
    });

    // Launch fast branch (5ms -> 2)
    auto tmFast = eventDriver.timers.create();
    eventDriver.timers.set(tmFast, 5.msecs, 0.msecs);
    eventDriver.timers.wait(tmFast, (TimerID tm) nothrow @safe {
        state.fastVal = 2;
        state.completed++;
        eventDriver.timers.releaseRef(tm);
        checkDone();
    });

    while (!state.done && eventDriver.core.waiterCount > 0)
        eventDriver.core.processEvents(Duration.max);

    assert(state.done);
    assert(state.slowVal == 1 && state.fastVal == 2);
}
