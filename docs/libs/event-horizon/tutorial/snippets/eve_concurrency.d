#!/usr/bin/env dub
/+ dub.sdl:
    name "eve_concurrency"
    dependency "eve" repository="git+https://codeberg.org/ddn/eve.git" version="c72f75135de636987e91bcd8ec5a22d32d34a197"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.stdio : writeln;
import eve;
import eve.rt;

void main() @safe
{
    auto loop = EventLoop.create();
    scope (exit) loop.dispose();

    auto pSlow = promise!int();
    auto pFast = promise!int();

    // Layer 1 callbacks are nothrow; Promise.resolve uses a Mutex and can throw
    loop.registerTimer(30, 0, (ref EventLoop l, Token t) @safe nothrow {
        try pSlow.resolve(1); catch (Exception error) { assert(false, error.msg); }
    });

    loop.registerTimer(5, 0, (ref EventLoop l, Token t) @safe nothrow {
        try pFast.resolve(2); catch (Exception error) { assert(false, error.msg); }
    });

    auto joined = all([pSlow, pFast]);
    int combined = 0;
    joined.then((int[] vals) @safe {
        combined = vals[0] * 10 + vals[1];
        try writeln("joined: ", combined); catch (Exception error) { assert(false, error.msg); }
        loop.stop();
    });

    loop.run();
    assert(combined == 12);
}
