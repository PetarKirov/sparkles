#!/usr/bin/env dub
/+ dub.sdl:
    name "eve_retry"
    dependency "eve" repository="git+https://codeberg.org/ddn/eve.git" version="c72f75135de636987e91bcd8ec5a22d32d34a197"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.stdio : writeln;
import eve;

void main() @safe
{
    auto loop = EventLoop.create();
    scope (exit) loop.dispose();

    int ticks = 0;
    int failures, value;
    // Register a repeating timer: initial delay 10ms, interval 10ms
    loop.registerTimer(10, 10, (ref EventLoop l, Token t) @safe nothrow {
        ticks++;
        auto error = tryOperation(ticks, value);
        if (error) { assert(error == 11); ++failures; return; }
        try if (ticks == 3) writeln("succeeded on attempt ", ticks); catch (Exception error) { assert(false, error.msg); }
        if (ticks >= 3)
            l.stop();
    });

    loop.run();
    assert(ticks == 3);
    assert(failures == 2 && value == 42);
}

int tryOperation(int attempt, out int value) @safe nothrow
{
    if (attempt < 3) return 11; // deterministic Linux EAGAIN injection
    value = 42;
    return 0;
}
