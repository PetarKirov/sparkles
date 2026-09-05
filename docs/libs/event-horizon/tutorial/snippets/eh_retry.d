#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_retry"
    dependency "sparkles:event-horizon" path="../../../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import core.stdc.errno : EAGAIN;
import std.stdio : writeln;
import sparkles.event_horizon;

void main()
{
    LoopGroup group;
    if (LoopGroup.start(group).hasError)
        assert(false, "no completion backend");
    scope (exit) group.shutdown();

    auto run = group.run((ref RootScope sc, ref Env env) {
        ref Sched s = currentScheduler();
        int attempts;
        auto outcome = withScope!((ref inner) {
            enum policy = exponential(5.msecs) & recurs(4);
            auto r = retry(inner, env.clock, policy, () {
                ++attempts;
                if (attempts < 3)
                    return ioErr!int(EAGAIN, OpKind.none, IoErrorStage.submit,
                        "flaky");
                return ioOk(attempts);
            });
            return r.hasValue ? r.value : -1;
        })(s);
        assert(outcome.hasValue && outcome.value == 3);
        writeln("succeeded on attempt ", outcome.value);
        return 0;
    });
    assert(run.hasValue);
}
