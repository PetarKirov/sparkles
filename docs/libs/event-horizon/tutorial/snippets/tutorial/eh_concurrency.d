#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_concurrency"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs;
import std.stdio : writeln, stderr;
import sparkles.event_horizon;

int main() @system
{
    auto result = runApplication((ref RootScope root, ref Env env) {
        JoinHandle!int slow, fast; // Slots remain pinned until both joins.
        root.fork(slow, () {
            auto slept = env.clock.sleep(20.msecs);
            return slept.hasError ? ioErr!int(slept.error) : ioOk(1);
        });
        root.fork(fast, () {
            auto slept = env.clock.sleep(5.msecs);
            return slept.hasError ? ioErr!int(slept.error) : ioOk(2);
        });
        auto a = root.join(slow);
        auto b = root.join(fast);
        if (a.hasError) root.fail(a.error);
        if (b.hasError) root.fail(b.error);
        if (!a.hasError && !b.hasError) writeln("joined: ", a.value * 10 + b.value);
        return ioOk();
    });
    if (result.hasError) stderr.writeln(result.error);
    return result.hasError ? 1 : 0;
}
