#!/usr/bin/env dub
/+ dub.sdl:
    name "vibe_signal"
    dependency "vibe-core" version="2.14.0"
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
    import vibe.core.sync : createSharedManualEvent;
    import core.thread : Thread;
    auto completed = createSharedManualEvent();
    auto thread = new Thread({ work(); completed.emit(); });
    thread.start();
    completed.wait(0); // parks the fiber, while the worker owns sigwait
    thread.join();
}
