#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_channel"
    dependency "sparkles:event-horizon" path="../../../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import core.stdc.errno : EPIPE;
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
        Channel!(int, 2) items; // capacity 2: the producer parks on the third put
        auto outcome = withScope!((ref sc) {
            assert(sc.spawn(() {
                foreach (i; 1 .. 6)
                    assert(!items.put(s, i).hasError);
                items.close();
            }));
            int sum;
            for (;;)
            {
                auto next = items.take(s); // parks while empty
                if (next.hasError)
                {
                    assert(next.error.errnoValue == EPIPE);
                    break; // closed and drained: EPIPE
                }
                assert(!env.clock.sleep(2.msecs).hasError); // the slow consumer
                sum += next.value;
            }
            return sum;
        })(s);
        assert(outcome.hasValue && outcome.value == 15);
        writeln("consumed: ", outcome.value);
        return 0;
    });
    assert(run.hasValue);
}
