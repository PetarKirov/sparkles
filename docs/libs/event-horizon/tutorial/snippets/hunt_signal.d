#!/usr/bin/env dub
/+ dub.sdl:
    name "hunt_signal"
    dependency "hunt-net" version="0.7.1"
    dependency "hunt" path=".deps/hunt"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import hunt.util.worker.Task : Task;
import core.thread : Thread;
import core.sys.posix.signal;
import core.sys.posix.pthread : pthread_self;
import std.stdio : writeln;

void main()
{
    stopStartupClock();
    // POSIX adapter in an explicitly joined Hunt Task, not a native Hunt signal API.
    int received;
    auto job = new class Task {
        override protected void doExecute() {
            sigset_t signals, previous;
            assert(sigemptyset(&signals) == 0);
            assert(sigaddset(&signals, SIGUSR1) == 0);
            assert(pthread_sigmask(SIG_BLOCK, &signals, &previous) == 0);
            scope(exit) assert(pthread_sigmask(SIG_SETMASK, &previous, null) == 0);
            assert(pthread_kill(pthread_self(), SIGUSR1) == 0);
            assert(sigwait(&signals, &received) == 0);
        }
    };
    auto worker = new Thread(&job.execute);
    worker.start();
    worker.join();
    assert(job.isDone() && received == SIGUSR1);
    writeln("got signal SIGUSR1");
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
