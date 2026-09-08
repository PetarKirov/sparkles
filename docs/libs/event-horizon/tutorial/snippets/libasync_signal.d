#!/usr/bin/env dub
/+ dub.sdl:
    name "libasync_signal"
    dependency "libasync" version="0.9.8"
    platforms "linux"
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
    import libasync;
    import core.thread : Thread;
    auto loop = new EventLoop();
    scope(exit) { loop.exit(); loop.destroy(); }
    auto notifier = new AsyncNotifier(loop);
    bool delivered;
    notifier.run({ delivered = true; notifier.kill(); });
    auto worker = new Thread({ work(); notifier.trigger(); });
    worker.start();
    while (!delivered) loop.loop();
    worker.join();
    assert(delivered);
}
