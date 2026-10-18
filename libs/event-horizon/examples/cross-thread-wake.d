#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_cross_thread_wake"
    dependency "sparkles:event-horizon" path="../../.."
    dependency "sparkles:base" path="../../.."
    platforms "linux" "osx"
    targetPath "build"
    // Platform default, or `-c libkqueue` for the Linux peer path.
    configuration "default-backend" {
        targetType "executable"
    }
    configuration "libkqueue" {
        targetType "executable"
        subConfiguration "sparkles:event-horizon" "libkqueue"
    }
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * A loop parked in `runOnce` is woken by another thread's `Waker.wake`
 * (SPEC §5.6) — the path a UI host takes when a platform thread hands it
 * work, and the one an Android app's every frame depends on.
 *
 * A second thread wakes the loop three times, 50 ms apart, while the loop
 * waits with a one-second deadline; each wait must end on the wake, well
 * before the deadline. The waker is armed while the process is still
 * single-threaded, the moment two past failures needed:
 *
 * - io_uring, Linux 6.16 and later: the in-ring `FUTEX_WAIT` was queued in the
 *   global futex hash, and creating the waking thread gave the process its
 *   private hash, where every `FUTEX_WAKE` looked and found no waiter. The
 *   backend now pins the private hash when it opens (SPEC §5.6).
 * - kqueue over libkqueue (Linux, Android): the wake knote was registered as
 *   macOS's `EVFILT_USER` (-10), which libkqueue, numbering filters as
 *   FreeBSD does (-11), rejected.
 *
 * Either way every wake was lost and only deadlines ended a wait.
 *
 * ---
 * dub run --single cross-thread-wake.d -b checked               # platform default
 * dub run --single cross-thread-wake.d -b checked -c libkqueue  # kqueue via libkqueue
 * ---
 *
 * `-c libkqueue` needs the sparkles nix devshell (`libs "kqueue"`). Prints
 * `SKIP:` and exits 0 if the backend cannot open.
 */
module event_horizon_cross_thread_wake;

import core.thread : Thread;
import core.time : Duration, msecs, MonoTime, seconds;

import sparkles.base.logger : LogLevel, info, initLogger, warning;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;

/// Backend this build resolved to (for ok/SKIP messages).
version (EventHorizonLibkqueue)
    enum backend = DefaultBackend.stringof ~ " (mheily/libkqueue)";
else
    enum backend = DefaultBackend.stringof;

enum wakes = 3;

int main()
{
    initLogger(LogLevel.info);

    DefaultLoop loop;
    auto created = DefaultLoop.create(loop, LoopConfig());
    if (created.hasError)
    {
        warning(i"SKIP: $(backend) unavailable (errno $(created.error.code)) — $(created.error.context)");
        return 0;
    }
    scope (exit) loop.destroy();

    auto armed = loop.waker();
    assert(!armed.hasError, "the loop hands out a waker");
    // Arming may report one iteration of its own; settle before timing.
    while (loop.runOnce(Duration.zero).value == RunStatus.dispatched)
    {
    }

    auto waker = armed.value;
    auto thread = new Thread({
        foreach (_; 0 .. wakes)
        {
            Thread.sleep(50.msecs);
            waker.wake();
        }
    });
    thread.start();
    scope (exit) thread.join();

    foreach (i; 0 .. wakes)
    {
        const before = MonoTime.currTime;
        const status = loop.runOnce(1.seconds);
        const waited = MonoTime.currTime - before;
        assert(!status.hasError);
        assert(status.value == RunStatus.dispatched && waited < 500.msecs,
            "a wait ended on its deadline, not on the other thread's wake");
    }
    info(i"ok: $(backend): $(wakes) cross-thread wakes each ended a blocked wait");
    return 0;
}
