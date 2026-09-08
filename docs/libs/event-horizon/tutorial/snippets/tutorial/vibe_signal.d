#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_vibe_signal"
    dependency "vibe-core" version="2.14.0"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.sys.posix.signal : sigset_t, sigemptyset, sigaddset, SIGUSR1,
    pthread_sigmask, SIG_BLOCK, SIG_SETMASK, pthread_kill, sigwait;
import core.sys.posix.pthread : pthread_self;
import core.thread : Thread;
import std.exception : enforce;
import std.stdio : writeln;
import vibe.core.sync : createSharedManualEvent;

void main() @system
{
    auto completed = createSharedManualEvent();
    Exception failure;
    int received;
    // POSIX adapter: sigwait lives on an OS thread, not in a signal handler.
    auto worker = new Thread({
        scope(exit) completed.emit();
        try
        {
            sigset_t signals, previous;
            enforce(sigemptyset(&signals) == 0 && sigaddset(&signals, SIGUSR1) == 0);
            enforce(pthread_sigmask(SIG_BLOCK, &signals, &previous) == 0);
            scope(exit) enforce(pthread_sigmask(SIG_SETMASK, &previous, null) == 0);
            enforce(pthread_kill(pthread_self(), SIGUSR1) == 0);
            enforce(sigwait(&signals, &received) == 0);
        }
        catch (Exception error) { failure = error; }
    });
    worker.start();
    completed.wait(0); // The waiting fiber parks.
    worker.join();
    if (failure !is null) throw failure;
    writeln("got signal ", received == SIGUSR1 ? "SIGUSR1" : "other");
}
