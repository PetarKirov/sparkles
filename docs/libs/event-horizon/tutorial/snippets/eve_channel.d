#!/usr/bin/env dub
/+ dub.sdl:
    name "eve_channel"
    dependency "eve" repository="git+https://codeberg.org/ddn/eve.git" version="c72f75135de636987e91bcd8ec5a22d32d34a197"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.stdio : writeln;
import eve;
import eve.rt;

void main() @safe
{
    auto loop = EventLoop.create();
    scope (exit) loop.dispose();

    auto ch = channel!int(2); // capacity 2: bounded channel
    assert(ch.trySend(1) == ChannelStatus.OK);
    assert(ch.trySend(2) == ChannelStatus.OK);
    assert(ch.trySend(3) == ChannelStatus.WOULD_BLOCK);
    int first;
    assert(ch.tryReceive(first) == ChannelStatus.OK && first == 1);
    assert(ch.trySend(3) == ChannelStatus.OK);
    assert(ch.trySend(4) == ChannelStatus.WOULD_BLOCK);
    int sum = 1;
    int nextToSend = 4;
    int expected = 2;

    // Producer timer on the event loop: pushes 1 .. 5 respecting backpressure
    loop.registerTimer(1, 1, (ref EventLoop l, Token t) @safe nothrow {
        try {
            while (nextToSend <= 5)
            {
                const st = ch.trySend(nextToSend);
                if (st == ChannelStatus.OK)
                    nextToSend++;
                else if (st == ChannelStatus.WOULD_BLOCK)
                    break; // backpressure: channel full, yield to event loop
                else
                    break;
            }
            if (nextToSend > 5)
            {
                ch.close();
                l.unregister(t);
            }
        } catch (Exception error) { assert(false, error.msg); }
    });

    // Consumer timer on the event loop: drains items
    loop.registerTimer(2, 2, (ref EventLoop l, Token t) @safe nothrow {
        try {
            int val;
            for (;;)
            {
                const st = ch.tryReceive(val);
                if (st == ChannelStatus.OK)
                {
                    assert(val == expected++);
                    sum += val;
                }
                else if (st == ChannelStatus.WOULD_BLOCK)
                {
                    break; // empty for now
                }
                else if (st == ChannelStatus.CLOSED)
                {
                    l.unregister(t);
                    writeln("consumed: ", sum);
                    l.stop();
                    break;
                }
            }
        } catch (Exception error) { assert(false, error.msg); }
    });

    loop.run();
    assert(sum == 15);
    assert(expected == 6);
}
