#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_signal"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.stdc.errno : errno;
import core.sys.posix.signal : SIGUSR1, kill;
import core.sys.posix.unistd : getpid;
import std.stdio : writeln, stderr;
import sparkles.event_horizon;

int main() @system
{
    SignalFd signals; // Block before starting runtime worker threads.
    auto opened = SignalFd.create(signals, [SIGUSR1]);
    if (opened.hasError) { stderr.writeln(opened.error); return 1; }
    auto result = runApplication((ref RootScope root, ref Env env) {
        if (kill(getpid(), SIGUSR1) != 0) return ioErr!void(errno, OpKind.none);
        auto received = signals.nextSignal(currentScheduler());
        if (received.hasError) return ioErr!void(received.error);
        writeln("got signal ", received.value == SIGUSR1 ? "SIGUSR1" : "other");
        return ioOk();
    });
    if (result.hasError) stderr.writeln(result.error);
    return result.hasError ? 1 : 0;
}
