#!/usr/bin/env dub
/+ dub.sdl:
    name "photon_concurrency"
    dependency "photon" version="0.19.3"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.stdio : writeln;
import photon;

void main()
{
    initPhoton();

    int joinedValue;
    go({
        int slowResult;
        int fastResult;

        // Uncoordinated fibers: return types are discarded; results captured in closures
        auto slow = go({
            delay(30.msecs);
            slowResult = 1;
        });
        auto fast = go({
            delay(5.msecs);
            fastResult = 2;
        });

        // Unstructured manual join; no enclosing lexical scope enforcement
        slow.join();
        fast.join();

        joinedValue = slowResult * 10 + fastResult;
        assert(joinedValue == 12);
        writeln("joined: ", joinedValue);
    });

    runScheduler();
    assert(joinedValue == 12);
}
