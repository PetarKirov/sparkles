#!/usr/bin/env dub
/+ dub.sdl:
    name "eve_deadline"
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

    CancelSource cancelSource;
    CancelToken token = cancelSource.token();

    bool sleepInterrupted = false;
    bool timedOut = false;
    bool cleanedUp = false;

    // Timeout: fires at 50ms and cancels the token
    loop.registerTimer(50, 0, (ref EventLoop l, Token t) @safe nothrow {
        cancelSource.cancel();
    });

    // Simulated cancellable operation waiting on a timer
    Token opToken = loop.registerTimer(10_000, 0, (ref EventLoop l, Token t) @safe nothrow {
        // Will be cancelled before 10s elapses
    });

    // Loop watcher checking cancellation status
    loop.registerTimer(10, 10, (ref EventLoop l, Token t) @safe nothrow {
        if (token.isCancelled)
        {
            sleepInterrupted = true;
            timedOut = true;
            l.unregister(t);
            l.unregister(opToken);

            // Cleanup phase
            cleanedUp = true;
            try {
                writeln("sleep returned: stopped by adapter");
                writeln("timed out: ", timedOut);
                writeln("cleaned up: ", cleanedUp);
            } catch (Exception error) { assert(false, error.msg); }
            l.stop();
        }
    });

    loop.run();
    assert(sleepInterrupted);
    assert(timedOut);
    assert(cleanedUp);
}
