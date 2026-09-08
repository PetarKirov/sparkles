#!/usr/bin/env dub
/+ dub.sdl:
    name "photon_retry"
    dependency "photon" version="0.19.3"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/

import photon;
import core.time : msecs;
import std.stdio : writeln;
void main()
{
    initPhoton();
    int attempts, value;
    go({
        while (attempts < 5)
        {
            ++attempts;
            const transientFailure = attempts < 3;
            if (!transientFailure) { value = attempts; break; }
            delay((5 << (attempts - 1)).msecs);
        }
    });
    runScheduler();
    assert(attempts == 3 && value == 3);
    writeln("succeeded on attempt ", value);
}
