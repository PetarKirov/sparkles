#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_signal"
    dependency "sparkles:event-horizon" path="../../../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.sys.posix.signal : SIGUSR1, kill;
import core.sys.posix.unistd : getpid;
import std.stdio : writeln;
import sparkles.event_horizon;

void main()
{
    SignalFd signals;
    if (SignalFd.create(signals, [SIGUSR1]).hasError)
        assert(false, "signalfd unavailable");

    LoopGroup group;
    if (LoopGroup.start(group).hasError)
        assert(false, "no completion backend");
    scope (exit) group.shutdown();

    auto run = group.run((ref RootScope sc, ref Env env) {
        ref Sched s = currentScheduler();
        assert(kill(getpid(), SIGUSR1) == 0);
        auto got = signals.nextSignal(s); // parks until the signal completes
        assert(got.hasValue && got.value == SIGUSR1);
        writeln("got signal ", got.value == SIGUSR1 ? "SIGUSR1" : "other");
        return 0;
    });
    assert(run.hasValue);
}
