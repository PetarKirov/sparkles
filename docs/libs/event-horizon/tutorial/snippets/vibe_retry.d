#!/usr/bin/env dub
/+ dub.sdl:
    name "vibe_retry"
    dependency "vibe-core" version="2.14.0"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.stdio : writeln;
import vibe.core.core : sleep;

void main()
{
    int attempts = 0;
    int maxAttempts = 5;
    auto delay = 5.msecs;
    int result = -1;

    for (int i = 0; i < maxAttempts; ++i)
    {
        ++attempts;
        try
        {
            if (attempts < 3)
                throw new Exception("flaky");
            result = attempts;
            break;
        }
        catch (Exception)
        {
            if (i + 1 == maxAttempts)
                throw new Exception("Max retries exceeded");
            sleep(delay);
            delay *= 2; // exponential backoff
        }
    }

    assert(result == 3);
    writeln("succeeded on attempt ", result);
}
