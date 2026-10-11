#!/usr/bin/env dub
/+ dub.sdl:
    name "mutex_throughput"
    dflags "-preview=dip1000" "-preview=in"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Throughput and fairness of five mutex designs on this machine, for
`docs/research/fine-grained-locking/comparison.md` § (a), the mutex word.

- `futex3`: the three-state futex word (unlocked, locked, contended) of
    Drepper's "Futexes Are Tricky" `mutex3`, glibc's `lll_lock` and Rust std,
    with Rust's bounded spin of 100.
- `parking`: a two-bit lock (`LOCKED`, `PARKED`) whose waiters queue in a
    global table of buckets hashed by address, each waiter parking on its own
    futex word — Rust `parking_lot`'s `RawMutex` and its `SpinWait`, without
    the bucket's `WordLock`, table growth or fair unlock.
- `parking+desig`: the same lock plus a designated-waker bit, as in nsync's
    `MU_DESIG_WAKER` and Abseil's `kMuDesig`: an unlock wakes a waiter only if
    no woken waiter is still on its way to the lock.
- `pthread`: druntime's `core.sync.mutex.Mutex`, a `pthread_mutex_t`.
- `ttas`: a test-and-test-and-set spin lock with exponential backoff and a
    `sched_yield` after 64 rounds — the baseline that no lock should be.

Every thread runs for a fixed time, taking the lock around a short critical
section. Each cell shows lock acquisitions per microsecond; fairness, the
fewest acquisitions any one thread made as a fraction of the most; and, for
the three futex locks, the `FUTEX_WAIT` and `FUTEX_WAKE` calls per
acquisition. A plain counter incremented under the lock checks mutual
exclusion. The numbers vary between runs and machines; the shapes are the
claim:

- With the cores saturated, `parking` sleeps on nearly every acquisition and
    collapses. Its `PARKED` bit is exact, so every unlock while the queue is
    non-empty wakes a waiter, which loses the race to a running thread and
    parks again. Rust's own `parking_lot` benchmark shows the same collapse
    (see the comparison). The three-state word avoids it by forgetting: a
    barging relock stores `locked`, so most unlocks wake nobody.
- `parking+desig` keeps the exact queue and wakes at most one waiter at a
    time: it sleeps on a fraction of a percent of acquisitions and has the
    highest throughput from two threads to oversubscription.
- The spin lock's fairness collapses once threads outnumber the cores.

Linux only (raw futex system calls); elsewhere it prints `SKIP:` and exits 0.
*/
module mutex_throughput;

version (linux)
    version = futexBench;

version (futexBench) {} else
{
    void main()
    {
        import std.stdio : writeln;

        writeln("SKIP: the futex-based locks need Linux");
    }
}

version (futexBench):

import core.atomic : atomicLoad, atomicOp, atomicStore, cas, pause;
import core.sys.linux.unistd : syscall;
import core.sys.posix.sched : sched_yield;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.algorithm : maxElement, minElement, sum;
import std.format : format;
import std.parallelism : totalCPUs;
import std.stdio : writefln, writeln;

version (X86_64)
    enum long sysFutex = 202;
else version (AArch64)
    enum long sysFutex = 98;
else
    static assert(0, "add this architecture's futex system call number");

enum int futexWaitPrivate = 128, futexWakePrivate = 129;

/// Wait and wake system calls made by this thread, so the table can show them
/// per acquisition. Thread-local: counting must not add contention.
ulong wakeCalls, waitCalls;

void futexWait(shared(uint)* word, uint expected) @system nothrow @nogc
{
    ++waitCalls;
    syscall(sysFutex, word, futexWaitPrivate, expected, null, null, 0);
}

void futexWake(shared(uint)* word, int count) @system nothrow @nogc
{
    ++wakeCalls;
    syscall(sysFutex, word, futexWakePrivate, count, null, null, 0);
}

/// The three-state futex mutex.
struct Futex3
{
    enum uint unlocked = 0, locked = 1, contended = 2;
    shared uint state;

    void lock() @system nothrow @nogc
    {
        if (cas(&state, unlocked, locked))
            return;
        // Spin while the lock is held but nobody waits (Rust std: 100).
        foreach (_; 0 .. 100)
        {
            const s = atomicLoad(state);
            if (s == unlocked && cas(&state, unlocked, locked))
                return;
            if (s == contended)
                break;
            pause();
        }
        // Mark it contended; whoever unlocks will wake one waiter.
        while (atomicExchange(&state, contended) != unlocked)
            futexWait(&state, contended);
    }

    void unlock() @system nothrow @nogc
    {
        if (atomicExchange(&state, unlocked) == contended)
            futexWake(&state, 1);
    }
}

uint atomicExchange(shared(uint)* p, uint v) @system nothrow @nogc
{
    import core.atomic : atomicExchange;

    return atomicExchange(p, v);
}

/// One parked thread's record, in the waiting thread's own storage.
struct Waiter
{
    const(void)* key;
    Waiter* next;
    shared uint unparked;
}

/// A bucket of the global wait-queue table: a spin lock and a FIFO.
struct Bucket
{
    shared uint guard;
    Waiter* head, tail;
    ubyte[64 - uint.sizeof - 2 * (Waiter*).sizeof] pad;

    void acquire() @system nothrow @nogc
    {
        // Test and test-and-set: spin on a load, so waiters do not steal the
        // line from the holder.
        while (atomicLoad(guard) || !cas(&guard, 0u, 1u))
            pause();
    }

    void release() @system nothrow @nogc => atomicStore(guard, 0u);
}

__gshared Bucket[256] table;

ref Bucket bucketOf(const(void)* key) @system nothrow @nogc
{
    // Fibonacci hashing of the address.
    const h = (cast(size_t) key * 0x9E3779B97F4A7C15UL) >> (size_t.sizeof * 8 - 8);
    return table[h];
}

/// The one-byte parking-lot mutex (held in a `uint` only for `cas`).
struct Parking
{
    enum uint lockedBit = 1, parkedBit = 2;
    shared uint state;

    void lock() @system nothrow @nogc
    {
        if (cas(&state, 0u, lockedBit))
            return;
        lockSlow();
    }

    void lockSlow() @system nothrow @nogc
    {
        uint spins;
        while (true)
        {
            auto s = atomicLoad(state);
            if (!(s & lockedBit))
            {
                if (cas(&state, s, s | lockedBit))
                    return;
                continue;
            }
            // Spin while nobody is parked: parking_lot's `SpinWait`, three rounds
            // of 2, 4 and 8 pauses, then yields, ten rounds in all.
            if (!(s & parkedBit) && spins < 10)
            {
                ++spins;
                if (spins <= 3)
                    foreach (_; 0 .. 1 << spins)
                        pause();
                else
                    sched_yield();
                continue;
            }
            if (!(s & parkedBit) && !cas(&state, s, s | parkedBit))
                continue;
            // Park: validate under the bucket lock, enqueue, sleep.
            Waiter me;
            me.key = &this;
            auto b = &bucketOf(&this);
            b.acquire();
            if (atomicLoad(state) != (lockedBit | parkedBit))
            {
                b.release();
                continue;
            }
            if (b.tail)
                b.tail.next = &me;
            else
                b.head = &me;
            b.tail = &me;
            b.release();
            while (!atomicLoad(me.unparked))
                futexWait(&me.unparked, 0);
            spins = 0;
        }
    }

    void unlock() @system nothrow @nogc
    {
        if (cas(&state, lockedBit, 0u))
            return;
        // Someone is parked: dequeue the first waiter for this lock.
        auto b = &bucketOf(&this);
        b.acquire();
        Waiter* prev, w = b.head;
        while (w && w.key !is &this)
        {
            prev = w;
            w = w.next;
        }
        bool more;
        if (w)
        {
            if (prev)
                prev.next = w.next;
            else
                b.head = w.next;
            if (b.tail is w)
                b.tail = prev;
            for (auto o = w.next; o; o = o.next)
                if (o.key is &this)
                {
                    more = true;
                    break;
                }
        }
        // Release, keeping PARKED while others still wait (no handoff: barging).
        atomicStore(state, more ? parkedBit : 0u);
        b.release();
        if (w)
        {
            atomicStore(w.unparked, 1u);
            futexWake(&w.unparked, 1);
        }
    }
}

/// The parking lock plus a designated-waker bit (nsync `MU_DESIG_WAKER`, Abseil
/// `kMuDesig`): at most one woken-but-not-running waiter per lock.
struct ParkingDesig
{
    enum uint lockedBit = 1, parkedBit = 2, wokenBit = 4;
    shared uint state;

    void lock() @system nothrow @nogc
    {
        if (cas(&state, 0u, lockedBit))
            return;
        lockSlow();
    }

    void lockSlow() @system nothrow @nogc
    {
        uint spins;
        bool designated;
        while (true)
        {
            auto s = atomicLoad(state);
            if (!(s & lockedBit))
            {
                const next = (s | lockedBit) & (designated ? ~wokenBit : ~0u);
                if (cas(&state, s, next))
                    return;
                continue;
            }
            if (!(s & parkedBit) && spins < 10)
            {
                ++spins;
                if (spins <= 3)
                    foreach (_; 0 .. 1 << spins)
                        pause();
                else
                    sched_yield();
                continue;
            }
            // About to sleep again: give up the designation first.
            if (designated)
            {
                if (!cas(&state, s, s & ~wokenBit))
                    continue;
                designated = false;
                s &= ~wokenBit;
            }
            if (!(s & parkedBit) && !cas(&state, s, s | parkedBit))
                continue;
            Waiter me;
            me.key = &this;
            auto b = &bucketOf(&this);
            b.acquire();
            const v = atomicLoad(state);
            if ((v & (lockedBit | parkedBit)) != (lockedBit | parkedBit))
            {
                b.release();
                continue;
            }
            if (b.tail)
                b.tail.next = &me;
            else
                b.head = &me;
            b.tail = &me;
            b.release();
            while (!atomicLoad(me.unparked))
                futexWait(&me.unparked, 0);
            designated = true;
            spins = 0;
        }
    }

    void unlock() @system nothrow @nogc
    {
        if (cas(&state, lockedBit, 0u))
            return;
        while (true)
        {
            const s = atomicLoad(state);
            // A designated waker is already on its way: just release.
            if ((s & wokenBit) || !(s & parkedBit))
            {
                if (cas(&state, s, s & ~lockedBit))
                    return;
                continue;
            }
            break;
        }
        auto b = &bucketOf(&this);
        b.acquire();
        Waiter* prev, w = b.head;
        while (w && w.key !is &this)
        {
            prev = w;
            w = w.next;
        }
        bool more;
        if (w)
        {
            if (prev)
                prev.next = w.next;
            else
                b.head = w.next;
            if (b.tail is w)
                b.tail = prev;
            for (auto o = w.next; o; o = o.next)
                if (o.key is &this)
                {
                    more = true;
                    break;
                }
        }
        atomicStore(state, (more ? parkedBit : 0u) | (w ? wokenBit : 0u));
        b.release();
        if (w)
        {
            atomicStore(w.unparked, 1u);
            futexWake(&w.unparked, 1);
        }
    }
}

/// druntime's mutex, a `pthread_mutex_t`.
struct Pthread
{
    import core.sync.mutex : Mutex;

    __gshared Mutex m;

    void lock() @system nothrow @nogc => m.lock_nothrow();
    void unlock() @system nothrow @nogc => m.unlock_nothrow();
}

/// A test-and-test-and-set spin lock with backoff.
struct Ttas
{
    shared uint state;

    void lock() @system nothrow @nogc
    {
        uint round;
        while (true)
        {
            if (!atomicLoad(state) && cas(&state, 0u, 1u))
                return;
            if (++round < 64)
                foreach (_; 0 .. 1 << (round < 8 ? round : 8))
                    pause();
            else
                sched_yield();
        }
    }

    void unlock() @system nothrow @nogc => atomicStore(state, 0u);
}

struct Result
{
    double opsPerUs;
    double fairness;
    double wakesPerOp, waitsPerOp;
}

/// Runs `threads` threads against one `L` for `ms` milliseconds.
Result run(L)(uint threads, uint ms) @system
{
    static if (is(L == Pthread))
    {
        import core.sync.mutex : Mutex;

        Pthread.m = new Mutex;
    }
    __gshared L lock;
    __gshared ulong guarded; // only touched under the lock
    __gshared ulong inside;  // a plain counter: a lost update means a broken lock
    static shared ulong sink;
    static shared bool stop;
    static shared ulong wakes, waits;
    atomicStore(wakes, 0UL);
    atomicStore(waits, 0UL);
    lock = L.init;
    guarded = 0;
    inside = 0;
    atomicStore(stop, false);
    auto counts = new ulong[threads];
    Thread[] workers;
    // A factory, not a loop body: closures made in a loop share one frame
    // (D issue 2043), so every worker would see the last `t`.
    Thread worker(uint id)
    {
        return new Thread({
            ulong n, local = id;
            while (!atomicLoad(stop))
            {
                lock.lock();
                // A short critical section: a few dependent updates.
                foreach (_; 0 .. 8)
                    guarded = guarded * 6_364_136_223_846_793_005UL + 1;
                ++n;
                inside = inside + 1;
                lock.unlock();
                // A little work outside the lock.
                foreach (_; 0 .. 16)
                    local = local * 2_862_933_555_777_941_757UL + 3_037_000_493UL;
            }
            counts[id] = n;
            atomicOp!"+="(sink, local); // keep `local` alive
            atomicOp!"+="(wakes, wakeCalls);
            atomicOp!"+="(waits, waitCalls);
        });
    }
    foreach (t; 0 .. threads)
        workers ~= worker(t);
    const start = MonoTime.currTime;
    foreach (w; workers)
        w.start();
    Thread.sleep(ms.msecs);
    atomicStore(stop, true);
    foreach (w; workers)
        w.join();
    const us = (MonoTime.currTime - start).total!"usecs";
    assert(inside == counts.sum, L.stringof ~ " let two threads into the critical section");
    return Result(counts.sum / cast(double) us,
        counts.minElement / cast(double) counts.maxElement,
        atomicLoad(wakes) / cast(double) counts.sum,
        atomicLoad(waits) / cast(double) counts.sum);
}

void main() @system
{
    const cores = totalCPUs;
    uint[] threadCounts = [1, 2, 4];
    if (cores > 4)
        threadCounts ~= cores;
    threadCounts ~= 2 * cores; // oversubscribed
    enum uint ms = 100;

    writefln("%u hardware threads; %u ms per cell; ops/µs, fairness (min/max ops per thread); per op: waits, wakes",
        cores, ms);
    writefln("%-9s%s", "threads", format!"%-28s%-28s%-28s%-20s%-20s"("futex3", "parking", "parking+desig", "pthread", "ttas"));
    foreach (n; threadCounts)
    {
        string row;
        static foreach (L; [`Futex3`, `Parking`, `ParkingDesig`, `Pthread`, `Ttas`])
        {{
            const r = run!(mixin(L))(n, ms);
            row ~= (L == `Pthread` || L == `Ttas`
                ? format!"%-20s"(format!"%7.2f %.2f"(r.opsPerUs, r.fairness))
                : format!"%-28s"(format!"%7.2f %.2f %.3f %.3f"(r.opsPerUs, r.fairness,
                    r.waitsPerOp, r.wakesPerOp)));
        }}
        writefln("%-9s%s", n == 2 * cores ? format!"%u*"(n) : format!"%u"(n), row);
    }
    writeln("* oversubscribed: more threads than hardware threads");
}
