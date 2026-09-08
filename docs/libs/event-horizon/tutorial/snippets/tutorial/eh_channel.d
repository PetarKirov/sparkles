#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_channel"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.stdc.errno : EPIPE;
import std.stdio : writeln, stderr;
import sparkles.event_horizon;

int main() @system
{
    Channel!(int, 2) items; // Outlives every producer/consumer operation.
    auto result = runApplication((ref RootScope root, ref Env env) {
        ref scheduler = currentScheduler();
        if (!root.spawn({
            scope(exit) items.close();
            foreach (value; 1 .. 6)
            {
                auto put = items.put(scheduler, value); // Parks when full.
                if (put.hasError) { root.fail(Cause!IoError.fromFailure(put.error)); return; }
            }
        })) return ioOk();
        int sum;
        for (;;)
        {
            auto next = items.take(scheduler); // Parks when empty.
            if (next.hasError)
            {
                if (next.error.errnoValue != EPIPE) return ioErr!void(next.error);
                break; // Closed and drained.
            }
            sum += next.value;
        }
        writeln("consumed: ", sum);
        return ioOk();
    });
    if (result.hasError) stderr.writeln(result.error);
    return result.hasError ? 1 : 0;
}
