/**
The benchmark gates of testing.md (B1–B7), measured by
`dub test :base -b bench -- --bench -i "sync\.bench"`.

The baseline is the three-state futex word (Drepper's `mutex3`, glibc's
`lll_lock`, Rust std's futex mutex), so the gates run on Linux; elsewhere
only B1 runs. B1 lands in the runner's table. B2–B7 are matrices of
time-boxed runs — each cell 100 ms, five runs, the median kept — whose
throughput, sleeps per acquisition and fairness are printed with each
gate's verdict. The verdicts bind only on the reference machine (the
32-hardware-thread Linux host of the survey); other legs log them.
*/
module sparkles.base.sync.bench_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : MonoTime, msecs;

import sparkles.base.sync;
import sparkles.base.sync.parking_lot : bucketIndex;
import sparkles.base.sync.seam : hasNativeSeam, seamFaults;
import sparkles.test_runner.attributes : benchmark, workload;

version (linux)
    private enum bool haveFutex3 = hasNativeSeam;
else
    private enum bool haveFutex3 = false;

// ---------------------------------------------------------------------------
// The baseline.

static if (haveFutex3)
{
    import core.sys.linux.unistd : syscall;

    version (X86_64)
        private enum long sysFutex = 202;
    else version (AArch64)
        private enum long sysFutex = 98;
    else
        private enum long sysFutex = 240;

    /// The three-state futex mutex, with Rust std's bounded spin of 100.
    private struct Futex3
    {
        shared uint state;

        void lock() @system nothrow @nogc
        {
            import core.atomic : atomicExchange, cas, pause;

            if (cas(&state, 0u, 1u))
                return;
            foreach (_; 0 .. 100)
            {
                const s = atomicLoad(state);
                if (s == 0 && cas(&state, 0u, 1u))
                    return;
                if (s == 2)
                    break;
                pause();
            }
            while (atomicExchange(&state, 2u) != 0)
            {
                ++seamFaults.waits;
                syscall(sysFutex, cast(void*) &state, 128, 2, null, null, 0);
            }
        }

        void unlock() @system nothrow @nogc
        {
            import core.atomic : atomicExchange;

            if (atomicExchange(&state, 0u) == 2)
            {
                ++seamFaults.wakes;
                syscall(sysFutex, cast(void*) &state, 129, 1, null, null, 0);
            }
        }
    }
}

/// `Mutex`'s and `InterruptibleMutex`'s lock/unlock behind one interface.
private struct MutexLock
{
    Mutex m;

    void lock() @safe nothrow @nogc => m.lock();
    void unlock() @safe nothrow @nogc => m.unlock();
}

private struct InterruptibleLock
{
    InterruptibleMutex m;

    // The package-internal acquisition and release, without a guard.
    void lock() @trusted nothrow @nogc
        => cast(void) (cast(shared(InterruptibleMutex)*) &m).acquireRaw(Deadline.never, true);

    void unlock() @trusted nothrow @nogc => (cast(shared(InterruptibleMutex)*) &m).release();
}

// ---------------------------------------------------------------------------
// B1: uncontended lock/unlock, one thread.

@("sync.bench.B1.uncontended")
@benchmark
@system unittest
{
    import sparkles.test_runner.bench : benchIter;

    __gshared Mutex m;
    __gshared InterruptibleMutex im;
    benchIter(() { m.lock(); m.unlock(); }, ["lock": "Mutex"]);
    benchIter(() { auto a = im.lock(); }, ["lock": "InterruptibleMutex"]);
    static if (haveFutex3)
    {
        __gshared Futex3 f;
        benchIter(() { f.lock(); f.unlock(); }, ["lock": "futex3"]);
    }
}

// ---------------------------------------------------------------------------
// B2–B4, B7: the contended matrix.

private struct Cell
{
    double throughput; /// acquisitions per microsecond
    double sleeps; /// seam waits per acquisition
    double fairness; /// fewest acquisitions any thread made ÷ the most
}

/// One run: `threads` threads for `ms` milliseconds, 8 iterations under the
/// lock and 16 outside, as the survey measured.
private Cell runCell(L)(ref L lock, uint threads, uint ms) @system
{
    static __gshared ulong counter;
    shared bool go, stop;
    auto counts = new shared(ulong)[threads];
    shared ulong sleeps;
    Thread[] ts;
    foreach (i; 0 .. threads)
        ts ~= new Thread(((uint id) => () {
            while (!atomicLoad(go)) {}
            const before = seamFaults.waits;
            ulong n, local;
            while (!atomicLoad(stop))
            {
                lock.lock();
                foreach (_; 0 .. 8)
                    ++counter;
                lock.unlock();
                foreach (_; 0 .. 16)
                    local = local * 6_364_136_223_846_793_005UL + 1;
                ++n;
            }
            atomicStore(counts[id], n);
            atomicOp!"+="(sleeps, seamFaults.waits - before);
            if (local == 42)
                counter += 1; // keep the outside work
        })(i)).start();
    atomicStore(go, true);
    Thread.sleep(ms.msecs);
    atomicStore(stop, true);
    foreach (t; ts)
        t.join();
    ulong total, lo = ulong.max, hi;
    foreach (c; counts)
    {
        const v = atomicLoad(c);
        total += v;
        lo = v < lo ? v : lo;
        hi = v > hi ? v : hi;
    }
    return Cell(total / (ms * 1000.0), total ? atomicLoad(sleeps) / cast(double) total : 0,
        hi ? lo / cast(double) hi : 0);
}

/// The median over five runs of each measure.
private Cell measure(L)(uint threads) @system
{
    import std.algorithm : sort;

    double[5] tp, sl, fa;
    foreach (r; 0 .. 5)
    {
        auto lock = new L;
        const c = runCell(*lock, threads, 100);
        tp[r] = c.throughput;
        sl[r] = c.sleeps;
        fa[r] = c.fairness;
    }
    sort(tp[]);
    sort(sl[]);
    sort(fa[]);
    return Cell(tp[2], sl[2], fa[2]);
}

@("sync.bench.B2-B4.B7.contended")
@workload
@system unittest
{
    import std.stdio : writefln, writeln;

    static if (!haveFutex3)
    {
        import sparkles.test_runner.skip : skipTest;

        skipTest("the gates compare against the Linux futex word");
    }
    else
    {
        bool b2 = true, b3 = true, b4 = true;
        writeln("\nB2–B4, B7: acquisitions/µs, sleeps/acquisition, fairness (median of 5 × 100 ms)");
        writefln("%8s | %24s | %24s | %24s", "threads", "futex3", "Mutex", "InterruptibleMutex");
        foreach (uint t; [2, 4, 32, 64])
        {
            const f = measure!Futex3(t);
            const m = measure!MutexLock(t);
            const i = measure!InterruptibleLock(t);
            writefln("%8d | %7.2f %7.4f %6.3f   | %7.2f %7.4f %6.3f   | %7.2f %7.4f %6.3f",
                t, f.throughput, f.sleeps, f.fairness, m.throughput, m.sleeps, m.fairness,
                i.throughput, i.sleeps, i.fairness);
            b2 &= m.throughput >= f.throughput;
            if (t >= 32)
                b3 &= m.sleeps <= 0.01;
            if (t == 32)
                b4 &= m.fairness >= f.fairness;
        }
        writefln("B2 throughput >= futex3 at every count: %s", b2 ? "pass" : "FAIL");
        writefln("B3 <= 0.01 sleeps/acquisition at 32 and 64: %s", b3 ? "pass" : "FAIL");
        writefln("B4 fairness >= futex3 at 32: %s", b4 ? "pass" : "FAIL");
        writeln("B7 InterruptibleMutex against Mutex: recorded above");
    }
}

// ---------------------------------------------------------------------------
// B5: the collision cost of the fixed table.

@("sync.bench.B5.collisions")
@workload
@system unittest
{
    import std.stdio : writefln, writeln;

    // Mutexes on their own cache lines, so only bucket sharing differs.
    static struct Padded
    {
        align(64) Mutex m;
    }

    auto pool = new Padded[64 * 1024];
    writeln("\nB5: k mutexes, each contended by 2 parking threads; one bucket ÷ distinct buckets");
    foreach (uint k; [2, 8, 64, 512])
    {
        // k mutexes in one bucket, and k in k distinct buckets.
        Mutex*[] same, distinct;
        const target = bucketIndex(cast(size_t) &pool[0].m);
        bool[size_t] used;
        foreach (ref p; pool)
        {
            const b = bucketIndex(cast(size_t) &p.m);
            if (same.length < k && b == target)
                same ~= &p.m;
            if (distinct.length < k && b !in used)
            {
                used[b] = true;
                distinct ~= &p.m;
            }
        }
        if (same.length < k)
        {
            writefln("%4d: not enough colliding addresses in the pool", k);
            continue;
        }
        const a = collisionRun(same), b = collisionRun(distinct);
        writefln("%4d mutexes: one bucket %.2f/µs, distinct %.2f/µs, fraction %.3f", k, a, b, a / b);
    }
    writeln("B5: recorded; the owner sets its pass threshold (DS2)");
}

private double collisionRun(Mutex*[] mutexes) @system
{
    shared bool go, stop;
    shared ulong total;
    Thread[] ts;
    foreach (m; mutexes)
        foreach (_; 0 .. 2)
            ts ~= new Thread(((Mutex* mm) => () {
                while (!atomicLoad(go)) {}
                ulong n;
                while (!atomicLoad(stop))
                {
                    mm.lock();
                    // Hold it long enough that the other thread parks.
                    foreach (__; 0 .. 64)
                        cast(void) atomicLoad(go);
                    mm.unlock();
                    ++n;
                }
                atomicOp!"+="(total, n);
            })(m), 64 * 1024).start();
    atomicStore(go, true);
    Thread.sleep(100.msecs);
    atomicStore(stop, true);
    foreach (t; ts)
        t.join();
    return atomicLoad(total) / 100_000.0;
}

// ---------------------------------------------------------------------------
// B6: notifyAll to 31 waiters with the lock held.

@("sync.bench.B6.notifyAllMorphs")
@workload
@system unittest
{
    import std.stdio : writefln;

    __gshared Mutex m;
    __gshared Condition c;
    __gshared int generation;
    enum waiters = 31, rounds = 200;
    shared int ready;
    shared ulong wakes, releases;
    Thread[] ts;
    foreach (_; 0 .. waiters)
        ts ~= new Thread({
            foreach (r; 1 .. rounds + 1)
            {
                const w0 = seamFaults.wakes;
                {
                    auto g = m.guard();
                    atomicOp!"+="(ready, 1);
                    while (generation < r)
                        c.wait(g);
                }
                atomicOp!"+="(releases, 1);
                atomicOp!"+="(wakes, seamFaults.wakes - w0);
            }
        }).start();
    foreach (r; 1 .. rounds + 1)
    {
        while (atomicLoad(ready) < waiters * r)
            Thread.yield();
        const w0 = seamFaults.wakes;
        {
            auto g = m.guard();
            ++generation;
            c.notifyAll();
        }
        atomicOp!"+="(releases, 1);
        atomicOp!"+="(wakes, seamFaults.wakes - w0);
    }
    foreach (t; ts)
        t.join();
    const perRelease = atomicLoad(wakes) / cast(double) atomicLoad(releases);
    writefln("\nB6: %.3f seam wakes per release of the lock (gate: at most 1): %s", perRelease,
        perRelease <= 1.0 ? "pass" : "FAIL");
}
