#!/usr/bin/env dub
/+ dub.sdl:
    name "ec_signal"
    dependency "eventcore" version="0.9.39"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.sys.posix.signal : SIGUSR1, kill;
import core.sys.posix.unistd : getpid;
import core.time : Duration;
import eventcore.core;
import std.stdio : writeln;

void main()
{
    bool done = false;

    auto id = eventDriver.signals.listen(SIGUSR1, (SignalListenID lid, SignalStatus status, int sig) nothrow @safe {
        assert(status == SignalStatus.ok);
        assert(sig == SIGUSR1);
        try writeln("got signal ", sig == SIGUSR1 ? "SIGUSR1" : "other");
        catch (Exception error) { assert(false, error.msg); }
        eventDriver.signals.releaseRef(lid);
        done = true;
    });
    assert(id != SignalListenID.invalid);

    assert(kill(getpid(), SIGUSR1) == 0);

    while (!done && eventDriver.core.waiterCount > 0)
        eventDriver.core.processEvents(Duration.max);

    assert(done);
}
