#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_vibe_channel"
    dependency "vibe-core" version="2.14.0"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;
import vibe.core.channel : createChannel;
import vibe.core.concurrency : async;

void main() @system
{
    auto items = createChannel!(int, 2)();
    auto producer = async({
        scope(exit) items.close();
        foreach (value; 1 .. 6) items.put(value); // Parks while full.
        return 0;
    });
    int sum, next;
    while (items.tryConsumeOne(next)) sum += next; // Ends after close and drain.
    producer.getResult(); // Join and propagate errors.
    writeln("consumed: ", sum);
}
