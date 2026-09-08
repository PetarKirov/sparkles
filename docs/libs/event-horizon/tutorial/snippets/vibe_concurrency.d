#!/usr/bin/env dub
/+ dub.sdl:
    name "vibe_concurrency"
    dependency "vibe-core" version="2.14.0"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.stdio : writeln;
import vibe.core.concurrency : async;
import vibe.core.core : sleep;

void main()
{
    auto slow = async({
        sleep(30.msecs);
        return 1;
    });
    auto fast = async({
        sleep(5.msecs);
        return 2;
    });

    const a = slow.getResult();
    const b = fast.getResult();

    assert(a * 10 + b == 12);
    writeln("joined: ", a * 10 + b);
}
