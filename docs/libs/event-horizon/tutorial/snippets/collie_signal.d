#!/usr/bin/env dub
/+ dub.sdl:
    name "collie_signal"
    dependency "collie" path=".deps/collie"
    dependency "kiss" path=".deps/kiss"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/

import core.sys.posix.signal;
import core.sys.posix.pthread : pthread_self;
import std.stdio : writeln;

void main()
{
    int received;
    // Application POSIX adapter. sigwait runs in ordinary thread context, so
    // no event, allocation or mutex operation is called from a signal handler.
    runWorker({
        sigset_t signals, previous;
        assert(sigemptyset(&signals) == 0);
        assert(sigaddset(&signals, SIGUSR1) == 0);
        assert(pthread_sigmask(SIG_BLOCK, &signals, &previous) == 0);
        scope(exit) assert(pthread_sigmask(SIG_SETMASK, &previous, null) == 0);
        assert(pthread_kill(pthread_self(), SIGUSR1) == 0);
        assert(sigwait(&signals, &received) == 0);
    });
    assert(received == SIGUSR1);
    writeln("got signal SIGUSR1");
}
void runWorker(void delegate() work)
{
    import kiss.event;
    import kiss.event.task : newTask;
    import core.thread : Thread;
    auto loop = new EventLoop();
    scope(exit) loop.dispose();
    bool delivered;
    auto worker = new Thread({
        work();
        loop.postTask(newTask({ delivered = true; loop.stop(); }));
    });
    worker.start();
    loop.run();
    worker.join();
    assert(delivered);
}
