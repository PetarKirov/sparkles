#!/usr/bin/env dub
/+ dub.sdl:
    name "photon_channel"
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

    int totalConsumed;
    go({
        // Channel with capacity 2: backpressure parks the producer on the 3rd put
        auto items = channel!int(2);
        int produced;
        bool attemptingThird;

        // Producer fiber: pushes 1..6 and closes the channel
        goOnSameThread({
            foreach (i; 1 .. 6)
            {
                if (i == 3) attemptingThird = true;
                items.put(i);
                produced = i;
            }
            items.close();
        });
        while (!attemptingThird) yield();
        assert(produced == 2);

        int sum;
        int expected = 1;
        // Consumer fiber: InputRange contract iterates until channel is closed & empty
        foreach (val; items)
        {
            assert(val == expected++);
            delay(2.msecs); // simulate slow consumer
            sum += val;
        }

        totalConsumed = sum;
        assert(totalConsumed == 15);
        assert(produced == 5 && expected == 6);
        writeln("consumed: ", totalConsumed);
    });

    runScheduler();
    assert(totalConsumed == 15);
}
