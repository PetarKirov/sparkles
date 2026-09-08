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
        int produced;
        bool attemptingThird;
        auto outcome = withScope!((ref sc) {
            assert(sc.spawn(() {
                foreach (i; 1 .. 6)
                {
                    if (i == 3) attemptingThird = true;
                    assert(!items.put(s, i).hasError);
                    produced = i;
                }
                items.close();
            }));
            while (!attemptingThird) s.yieldNow();
            assert(produced == 2, "third put must remain pending while full");
            auto first = items.take(s);
            assert(first.hasValue && first.value == 1);
            while (produced < 3) s.yieldNow();
            assert(produced == 3, "one freed slot permits exactly one put");
            int sum = 1;
            int expected = 2;
            for (;;)
            {
                auto next = items.take(s); // parks while empty
                if (next.hasError)
                {
                    assert(next.error.errnoValue == EPIPE);
                    break; // closed and drained: EPIPE
                }
                assert(next.value == expected++);
                assert(!env.clock.sleep(2.msecs).hasError); // the slow consumer
                sum += next.value;
            }
            assert(expected == 6 && produced == 5);
            return sum;
        })(s);
        assert(outcome.hasValue && outcome.value == 15);
        writeln("consumed: ", outcome.value);
        return 0;
    });
    assert(run.hasValue);
}
