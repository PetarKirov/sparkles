#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_timers"
    dependency "sparkles:event-horizon" path="../../../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.stdio : writeln;
import sparkles.event_horizon;

void main()
{
    LoopGroup group;
    if (LoopGroup.start(group).hasError)
        assert(false, "no completion backend");
    scope (exit) group.shutdown();

    int ticks;
    auto run = group.run((ref RootScope sc, ref Env env) {
        foreach (i; 1 .. 4)
        {
            assert(!env.clock.sleep(10.msecs).hasError); // parks this fiber only
            writeln("tick ", i);
            ++ticks;
        }
        return 0;
    });
    assert(run.hasValue);
    assert(ticks == 3);
}
