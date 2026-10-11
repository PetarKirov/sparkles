#!/usr/bin/env dub
/+ dub.sdl:
    name "handoff_latency"
    dflags "-preview=dip1000" "-preview=in"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
The round-trip time of handing a turn between two threads that sleep while
waiting, for `docs/research/fine-grained-locking/comparison.md` § (d), fibers
waiting on a word. Three mechanisms:

- `futex`: a word per direction, `FUTEX_WAIT` on it and `FUTEX_WAKE` after
    storing — what a wait-on-address primitive costs at its floor.
- `eventfd`: a counter per direction, a blocking `read` and a `write` — what
    an event loop's file-descriptor waker costs.
- `pthread cond`: a mutex and a condition variable, the turn kept under the
    mutex — druntime's `core.sync.condition.Condition`.

Every wait really sleeps: there is no spinning before it, so the numbers are
the cost of a sleep and a wake-up, scheduler latency included. They vary
between machines; on one they compare the mechanisms.

Linux only; elsewhere it prints `SKIP:` and exits 0.
*/
module handoff_latency;

version (linux)
    version = linuxBench;

version (linuxBench) {} else
{
    void main()
    {
        import std.stdio : writeln;

        writeln("SKIP: the futex and eventfd mechanisms need Linux");
    }
}

version (linuxBench):

import core.atomic : atomicLoad, atomicStore;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.sys.linux.sys.eventfd : eventfd;
import core.sys.linux.unistd : syscall;
import core.sys.posix.unistd : close, read, write;
import core.thread : Thread;
import core.time : MonoTime;
import std.stdio : writefln;

version (X86_64)
    enum long sysFutex = 202;
else version (AArch64)
    enum long sysFutex = 98;
else
    static assert(0, "add this architecture's futex system call number");

enum int futexWaitPrivate = 128, futexWakePrivate = 129;
enum rounds = 20_000;

/// Runs `rounds` round trips: `ping` hands the turn over and waits for it
/// back; `pong` waits, then hands it back. Returns microseconds per round trip.
double measure(void delegate() ping, void delegate() pong) @system
{
    auto other = new Thread({
        foreach (_; 0 .. rounds)
            pong();
    });
    other.start();
    const start = MonoTime.currTime;
    foreach (_; 0 .. rounds)
        ping();
    const elapsed = MonoTime.currTime - start;
    other.join();
    return elapsed.total!"nsecs" / 1000.0 / rounds;
}

/// A word one thread sleeps on until another sets it.
struct FutexFlag
{
    shared uint word;

    void wait() @system nothrow @nogc
    {
        while (!atomicLoad(word))
            syscall(sysFutex, &word, futexWaitPrivate, 0, null, null, 0);
        atomicStore(word, 0u);
    }

    void post() @system nothrow @nogc
    {
        atomicStore(word, 1u);
        syscall(sysFutex, &word, futexWakePrivate, 1, null, null, 0);
    }
}

void main() @system
{
    // futex
    FutexFlag toPong, toPing;
    const futexUs = measure(() { toPong.post(); toPing.wait(); },
        () { toPong.wait(); toPing.post(); });

    // eventfd
    const a = eventfd(0, 0), b = eventfd(0, 0);
    scope (exit)
    {
        close(a);
        close(b);
    }
    ulong one = 1, got;
    const eventfdUs = measure(() { write(a, &one, 8); read(b, &got, 8); },
        () { read(a, &got, 8); write(b, &one, 8); });

    // pthread condition variable
    auto m = new Mutex;
    auto cond = new Condition(m);
    bool pongTurn;
    const condUs = measure(() {
        m.lock();
        pongTurn = true;
        cond.notifyAll();
        while (pongTurn)
            cond.wait();
        m.unlock();
    }, () {
        m.lock();
        while (!pongTurn)
            cond.wait();
        pongTurn = false;
        cond.notifyAll();
        m.unlock();
    });

    writefln("%u round trips each; microseconds per round trip (two sleeps, two wakes)", rounds);
    writefln("  %-14s %6.2f", "futex", futexUs);
    writefln("  %-14s %6.2f", "eventfd", eventfdUs);
    writefln("  %-14s %6.2f", "pthread cond", condUs);
}
