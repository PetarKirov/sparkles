#!/usr/bin/env dub
/+ dub.sdl:
    name "ec_channel"
    dependency "eventcore" version="0.9.39"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : Duration, msecs;
import eventcore.core;
import std.stdio : writeln;

// In eventcore, backpressure requires rolling your own ring buffer and dual EventIDs
struct BoundedQueue
{
    int[2] ring;
    size_t head;
    size_t tail;
    size_t count;
    bool closed;
    EventID hasData;
    EventID hasSpace;

    bool push(int val) @safe nothrow
    {
        if (count >= ring.length || closed) return false;
        ring[tail] = val;
        tail = (tail + 1) % ring.length;
        count++;
        eventDriver.events.trigger(hasData, false);
        return true;
    }

    bool pop(out int val) @safe nothrow
    {
        if (count == 0) return false;
        val = ring[head];
        head = (head + 1) % ring.length;
        count--;
        eventDriver.events.trigger(hasSpace, false);
        return true;
    }
}

void main()
{
    BoundedQueue q;
    q.hasData = eventDriver.events.create();
    q.hasSpace = eventDriver.events.create();

    assert(q.push(1) && q.push(2));
    assert(!q.push(3), "full adapter rejects the third item");
    int first;
    assert(q.pop(first) && first == 1);
    assert(q.push(3) && !q.push(4));
    int nextProduce = 4;
    int sum = 1;
    int expected = 2;
    bool consumerDone = false;

    // Producer callback
    void produce(EventID) nothrow @safe
    {
        while (nextProduce <= 5)
        {
            if (!q.push(nextProduce))
            {
                // Queue full: apply backpressure by waiting for space event
                eventDriver.events.wait(q.hasSpace, &produce);
                return;
            }
            nextProduce++;
        }
        q.closed = true;
        eventDriver.events.trigger(q.hasData, false);
    }

    // Consumer callback
    void consume(EventID) nothrow @safe
    {
        int item;
        while (q.pop(item))
        {
            assert(item == expected++);
            sum += item;
        }

        if (q.closed && q.count == 0)
        {
            consumerDone = true;
            try writeln("consumed: ", sum);
            catch (Exception error) { assert(false, error.msg); }
            return;
        }

        // Wait for more data
        eventDriver.events.wait(q.hasData, &consume);
    }

    // Local trigger() is synchronous and is not a stored notification. Drain
    // the prefilled queue before arming the next wait; otherwise both callbacks
    // can wait forever for an edge that happened before either was registered.
    consume(q.hasData);
    produce(q.hasSpace);

    while (!consumerDone && eventDriver.core.waiterCount > 0)
        eventDriver.core.processEvents(Duration.max);

    eventDriver.events.releaseRef(q.hasData);
    eventDriver.events.releaseRef(q.hasSpace);

    assert(consumerDone);
    assert(sum == 15);
    assert(expected == 6 && q.closed && q.count == 0);
}
