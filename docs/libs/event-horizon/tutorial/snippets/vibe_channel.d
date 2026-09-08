#!/usr/bin/env dub
/+ dub.sdl:
    name "vibe_channel"
    dependency "vibe-core" version="2.14.0"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.stdio : writeln;
import vibe.core.channel : createChannel;
import vibe.core.core : runTask, sleep, yield;

void main()
{
    auto items = createChannel!(int, 2)();
    int produced;
    bool attemptingThird;

    auto producer = runTask(() nothrow {
        try
        {
            foreach (i; 1 .. 6)
            {
                if (i == 3) attemptingThird = true;
                items.put(i);
                produced = i;
            }
            items.close();
        }
        catch (Exception error) { assert(false, error.msg); }
    });

    while (!attemptingThird) yield();
    assert(produced == 2 && items.bufferFill == 2);
    int sum = 0;
    int expected = 1;
    int next;
    while (items.tryConsumeOne(next))
    {
        assert(next == expected++);
        sleep(2.msecs);
        sum += next;
    }

    producer.join();

    assert(sum == 15);
    assert(produced == 5 && expected == 6);
    writeln("consumed: ", sum);
}
