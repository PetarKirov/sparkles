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
        Channel!(int, 2) ready, release;
        int finished;
        auto outcome = withScope!((ref sc) {
            JoinHandle!int slow, fast;
            sc.fork(slow, () {
                assert(!ready.put(s, 1).hasError);
                assert(!release.take(s).hasError);
                ++finished;
                return ioOk(1); // an IoResult: the typed success or IoError
            });
            sc.fork(fast, () {
                assert(!ready.put(s, 2).hasError);
                assert(!release.take(s).hasError);
                ++finished;
                return ioOk(2);
            });
            // Both children have started, but neither can finish yet.
            assert(!ready.take(s).hasError && !ready.take(s).hasError);
            assert(finished == 0);
            assert(!release.put(s, 0).hasError && !release.put(s, 0).hasError);
            // Release both and join in either order; no scheduling-time assumption.
            auto a = slow.join(s);
            auto b = fast.join(s);
            assert(a.hasValue && b.hasValue);
            return a.value * 10 + b.value;
        })(s);
        assert(outcome.hasValue && outcome.value == 12);
        assert(finished == 2);
        writeln("joined: ", outcome.value);
        return 0;
    });
    assert(run.hasValue);
}
