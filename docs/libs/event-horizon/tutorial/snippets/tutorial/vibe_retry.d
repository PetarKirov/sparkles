#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_vibe_retry"
    dependency "vibe-core" version="2.14.0"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs;
import std.stdio : writeln;
import vibe.core.core : sleep;

class TransientFailure : Exception
{
    this() @safe { super("try again"); }
}
void main() @system
{
    foreach (attempt; 1 .. 6)
    {
        try
        {
            if (attempt < 3) throw new TransientFailure;
            writeln("succeeded on attempt ", attempt);
            break;
        }
        catch (TransientFailure error)
        {
            if (attempt == 5) throw error;
            sleep((5 << (attempt - 1)).msecs);
        }
    }
}
