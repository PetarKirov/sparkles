#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_callback_timers"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs;
import std.stdio : writeln, stderr;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion;

struct Timer
{
    int ticks;
    int error;
}

void tick(ref Timer timer, ref Completion done) nothrow @nogc
{
    if (done.res < 0) timer.error = done.res;
    else ++timer.ticks;
}

int main() @system
{
    Timer timer; // Outlives the loop, including cleanup after a drive error.
    DefaultLoop loop;
    auto started = DefaultLoop.create(loop);
    if (started.hasError) { stderr.writeln(started.error); return 1; }
    scope(exit) loop.destroy();
    foreach (number; 1 .. 4)
    {
        auto armed = loop.submitAfter!tick(10.msecs, timer);
        if (armed.hasError) { stderr.writeln(armed.error); return 1; }
        auto ran = loop.run();
        if (ran.hasError) { stderr.writeln(ran.error); return 1; }
        if (timer.error) { stderr.writeln("timer failed: ", timer.error); return 1; }
        writeln("tick ", timer.ticks);
    }
    return 0;
}
