#!/usr/bin/env dub
/+ dub.sdl:
    name "hunt_channel"
    dependency "hunt-net" version="0.7.1"
    dependency "hunt" path=".deps/hunt"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.stdio : writeln;
import core.time : msecs;
import core.thread : Thread;
import core.stdc.stdlib : exit;
import std.parallelism : task, taskPool;
import hunt.util.queue.SimpleQueue;

void main()
{
    stopStartupClock();
    // hunt relies on heap-allocated queues (SimpleQueue) protected by Mutex/Condition;
    // unlike event-horizon's bounded Channel!T which parks fibers on full/empty,
    // SimpleQueue is an unbounded GC-allocated list with no producer backpressure.
    auto queue = new SimpleQueue!int(500.msecs);
    int sum = 0;

    auto producer = task({
        foreach (i; 1 .. 6) {
            queue.push(i);
        }
    });
    taskPool.put(producer);
    producer.yieldForce(); // unbounded queue: producer finishes before any consumer
    assert(!queue.isEmpty());

    foreach (_; 1 .. 6) {
        int item = queue.pop();
        assert(item == _);
        Thread.sleep(2.msecs); // simulate consumer processing
        sum += item;
    }

    assert(sum == 15);
    assert(queue.isEmpty());
    writeln("consumed: ", sum);
}

// Standalone-process workaround for the pinned Hunt DateTime daemon: its
// destructor stops but does not join. Join before creating application threads.
void stopStartupClock()
{
    import core.thread : Thread;
    import hunt.util.DateTime : DateTime;
    auto startupThreads = Thread.getAll();
    assert(startupThreads.length <= 2, "review startup ownership if dependencies change");
    DateTime.stopClock();
    foreach (thread; startupThreads)
        if (thread !is Thread.getThis())
        {
            assert(thread.isDaemon);
            thread.join();
        }
}
