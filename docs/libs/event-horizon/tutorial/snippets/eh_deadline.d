#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_deadline"
    dependency "sparkles:event-horizon" path="../../../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs, seconds;
import core.stdc.errno : ECANCELED;
import std.stdio : writeln;
import sparkles.event_horizon;

void main()
{
    LoopGroup group;
    if (LoopGroup.start(group).hasError)
        assert(false, "no completion backend");
    scope (exit) group.shutdown();

    auto run = group.run((ref RootScope root, ref Env env) {
        ref Sched s = currentScheduler();
        bool cleanedUp;
        auto outcome = withDeadline!((ref sc) {
            auto slept = env.clock.sleep(10.seconds); // interrupted at 50 ms
            writeln("sleep returned: ", slept.hasError ? "ECANCELED" : "ok");
            assert(slept.hasError && slept.error.errnoValue == ECANCELED);
            // Cleanup runs to completion even though the fiber is cancelled.
            cast(void) protect!(() {
                assert(!env.clock.sleep(5.msecs).hasError);
                cleanedUp = true;
                return 0;
            })(s);
            return 0;
        })(s, 50.msecs);
        assert(outcome.hasError && outcome.error.isTimeout);
        assert(cleanedUp);
        writeln("timed out: ", outcome.hasError && outcome.error.isTimeout);
        writeln("cleaned up: ", cleanedUp);
        return 0;
    });
    assert(run.hasValue);
}
