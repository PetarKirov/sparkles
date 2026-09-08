#!/usr/bin/env dub
/+ dub.sdl:
    name "hunt_deadline"
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
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.stdc.stdlib : exit;

void main()
{
    stopStartupClock();
    runWorker({
        // Application-side condition timeout; this is not a hunt-net cancellation API.
        // there are no structured cancel scopes, so cancellation is simulated
        // by signaling a condition variable or closing the connection session.
        auto mtx = new Mutex();
        auto cond = new Condition(mtx);
        bool timedOut = false;
        bool cleanedUp = false;
        string sleepStatus;

        // Simulate an operation waiting with a 50ms deadline
        synchronized (mtx) {
            bool notified = cond.wait(50.msecs);
            if (!notified) {
                timedOut = true;
                sleepStatus = "stopped by adapter"; // deadline expired before 10s passed
            } else {
                sleepStatus = "ok";
            }
        }

        writeln("sleep returned: ", sleepStatus);

        // In hunt-net, cleanup must be executed explicitly in try/finally or closed handlers
        try {
            Thread.sleep(5.msecs);
            cleanedUp = true;
        } finally {
            assert(timedOut);
            assert(cleanedUp);
        }

        writeln("timed out: ", timedOut);
        writeln("cleaned up: ", cleanedUp);
    });
}

void runWorker(void delegate() work)
{
    import hunt.util.worker.Task : Task;
    import core.thread : Thread;
    auto job = new class Task {
        override protected void doExecute() { work(); }
    };
    auto thread = new Thread(&job.execute);
    thread.start();
    thread.join();
    assert(job.isDone());
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
