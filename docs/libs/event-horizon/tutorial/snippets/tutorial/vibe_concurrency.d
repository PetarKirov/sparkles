#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_vibe_concurrency"
    dependency "vibe-core" version="2.14.0"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs;
import std.stdio : writeln;
import vibe.core.concurrency : async;
import vibe.core.core : sleep;

void main() @system
{
    auto slow = async({ sleep(20.msecs); return 1; });
    auto fast = async({ sleep(5.msecs); return 2; });
    // Join both before retrieving values, which can propagate task exceptions.
    slow.task.join();
    fast.task.join();
    writeln("joined: ", slow.getResult() * 10 + fast.getResult());
}
