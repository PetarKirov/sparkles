#!/usr/bin/env dub
/+ dub.sdl:
    name "libasync_channel"
    dependency "libasync" version="0.9.8"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.stdio : writeln;
import libasync;

void main()
{
    auto evl = new EventLoop;
    scope (exit) { evl.exit(); evl.destroy(); }

    // libasync lacks built-in channels with backpressure.
    // Developers had to hand-roll bounded ring buffers with manual notifier signaling.
    int[2] buffer;
    size_t count = 0;
    int nextItem = 1;
    int sum = 0;
    bool done = false;

    auto notifier = new AsyncNotifier(evl);

    // Consumer step: runs on the event loop when triggered
    notifier.run({
        if (count > 0)
        {
            // Take one item (slow consumer)
            sum += buffer[0];
            buffer[0] = buffer[1];
            count--;

            // Produce more if space is available
            while (count < 2 && nextItem <= 5)
            {
                buffer[count++] = nextItem++;
            }

            if (count == 0 && nextItem > 5)
            {
                done = true;
                notifier.kill();
                return;
            }

            // Trigger next consumption iteration
            notifier.trigger();
        }
    });

    // Fill initial bounded capacity (2 items)
    while (count < 2 && nextItem <= 5)
        buffer[count++] = nextItem++;
    assert(count == 2 && nextItem == 3, "bounded adapter admits only two items before dispatch");

    notifier.trigger();

    while (!done)
        evl.loop();

    assert(sum == 15);
    writeln("consumed: ", sum);
}
