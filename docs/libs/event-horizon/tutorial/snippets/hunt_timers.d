#!/usr/bin/env dub
/+ dub.sdl:
    name "hunt_timers"
    dependency "hunt-net" version="0.7.1"
    dependency "hunt" path=".deps/hunt"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.stdio : writeln;
import core.time : Duration, msecs;
import core.sync.semaphore : Semaphore;
import core.stdc.stdlib : exit;
import core.sys.posix.unistd : read;
import hunt.event.EventLoop;
import hunt.event.selector.Selector;
import hunt.util.Timer;
import hunt.net.EventLoopPool : EventLoopObjectFactory;
import hunt.Functions;

// Hunt's AbstractTimer has an upstream 4-byte buffer overflow bug reading
// timerfd (reading 8 bytes into a 32-bit uint). We subclass it safely here.
class SafeTimer : Timer {
    this(Selector loop, Duration dur) {
        super(loop, dur);
    }

    override bool readTimer(scope SimpleActionHandler handler) {
        this.clearError();
        ulong value;
        read(this.handle, &value, 8);
        this._readBuffer.data = cast(uint) value;
        if (handler)
            handler(this._readBuffer);
        return false;
    }
}

void main()
{
    stopStartupClock();
    EventLoop loop = EventLoopObjectFactory.buildEventLoop();
    scope(exit) loop.stop();
    auto sem = new Semaphore(0);
    int count = 0;

    auto timer = new SafeTimer(loop, 10.msecs);
    timer.onTick((Object sender) {
        count++;
        writeln("tick ", count);
        if (count == 3) {
            timer.stop();
            sem.notify();
        }
    });
    timer.start();

    sem.wait();
    assert(count == 3);
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
