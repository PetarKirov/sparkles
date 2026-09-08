#!/usr/bin/env dub
/+ dub.sdl:
    name "hunt_concurrency"
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
import std.parallelism : task, taskPool;

void main()
{
    stopStartupClock();
    runWorker({
        // Application-side Phobos worker adapter, not a hunt-net task-scope API.
        auto mtx = new Mutex();
        auto cond = new Condition(mtx);
        int a = 0;
        int b = 0;
        int finished = 0;

        auto taskA = task({
            Thread.sleep(30.msecs);
            synchronized (mtx) {
                a = 1;
                finished++;
                if (finished == 2) cond.notify();
            }
    });

    auto taskB = task({
        Thread.sleep(5.msecs);
        synchronized (mtx) {
            b = 2;
            finished++;
            if (finished == 2) cond.notify();
        }
    });

    taskPool.put(taskA);
    taskPool.put(taskB);

    synchronized (mtx) {
        while (finished < 2)
            cond.wait();
    }

    int joined = a * 10 + b;
    assert(joined == 12);
    writeln("joined: ", joined);
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
