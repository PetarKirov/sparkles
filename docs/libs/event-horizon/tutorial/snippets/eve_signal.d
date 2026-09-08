#!/usr/bin/env dub
/+ dub.sdl:
    name "eve_signal"
    dependency "eve" repository="git+https://codeberg.org/ddn/eve.git" version="c72f75135de636987e91bcd8ec5a22d32d34a197"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.sys.posix.signal : SIGUSR1, kill;
import core.sys.posix.unistd : getpid;
import std.stdio : writeln;
import eve;

void main() @safe
{
    auto loop = EventLoop.create();
    scope (exit) loop.dispose();

    bool gotSignal = false;

    loop.registerSignal(Signal.USER1, (ref EventLoop l, Token t, SignalInfo info) @safe nothrow {
        if (info.signal == Signal.USER1)
        {
            gotSignal = true;
            try writeln("got signal SIGUSR1"); catch (Exception error) { assert(false, error.msg); }
        }
        l.stop();
    });

    // Send SIGUSR1 to own process
    () @trusted { assert(kill(getpid(), SIGUSR1) == 0); }();

    loop.run();
    assert(gotSignal);
}
