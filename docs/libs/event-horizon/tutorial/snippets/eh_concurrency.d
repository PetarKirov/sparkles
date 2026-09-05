#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_concurrency"
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

    auto run = group.run((ref RootScope root, ref Env env) {
        ref Sched s = currentScheduler();
        auto outcome = withScope!((ref sc) {
            JoinHandle!int slow, fast;
            sc.fork(slow, () {
                assert(!env.clock.sleep(30.msecs).hasError);
                return ioOk(1); // an IoResult: the typed success or IoError
            });
            sc.fork(fast, () {
                assert(!env.clock.sleep(5.msecs).hasError);
                return ioOk(2);
            });
            // Both run concurrently; join in any order.
            auto a = slow.join(s);
            auto b = fast.join(s);
            assert(a.hasValue && b.hasValue);
            return a.value * 10 + b.value;
        })(s);
        assert(outcome.hasValue && outcome.value == 12);
        writeln("joined: ", outcome.value);
        return 0;
    });
    assert(run.hasValue);
}
