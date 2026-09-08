#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_timers"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs;
import std.stdio : writeln, stderr;
import sparkles.event_horizon : runApplication, RootScope, Env, ioOk;

int main() @system
{
    auto result = runApplication((ref RootScope root, ref Env env) {
        foreach (tick; 1 .. 4)
        {
            auto slept = env.clock.sleep(10.msecs);
            if (slept.hasError) return slept;
            writeln("tick ", tick);
        }
        return ioOk();
    });
    if (result.hasError) stderr.writeln(result.error);
    return result.hasError ? 1 : 0;
}
