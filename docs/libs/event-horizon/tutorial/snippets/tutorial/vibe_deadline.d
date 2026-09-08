#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_vibe_deadline"
    dependency "vibe-core" version="2.14.0"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs, seconds;
import std.stdio : writeln;
import vibe.core.concurrency : async;
import vibe.core.core : setTimer, sleep, sleepUninterruptible;
import vibe.core.task : InterruptException;

void main() @system
{
    bool cleaned;
    auto work = async({
        scope(exit) { sleepUninterruptible(5.msecs); cleaned = true; }
        try { sleep(10.seconds); return false; }
        catch (InterruptException) { return true; }
    });
    auto timer = setTimer(50.msecs, () nothrow { work.task.interrupt(); });
    scope(exit) timer.stop();
    const interrupted = work.getResult(); // Other task exceptions propagate.
    writeln("sleep returned: ", interrupted ? "InterruptException" : "ok");
    writeln("timed out: ", interrupted);
    writeln("cleaned up: ", cleaned);
}
