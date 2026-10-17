/**
Tests of `Mutex` and `LockBits`: oracle 1 scenarios for SYM2–SYM9 and
SYL1–SYL2 with their seeded faults, compile-time checks (oracle 6) and native
stress (oracle 3).
*/
module sparkles.base.sync.mutex_test;

import core.thread : Thread;
import core.time : MonoTime, msecs;

import sparkles.base.sync.model;
import sparkles.base.sync.mutex;
import sparkles.base.sync.parker : pins;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.seam : Deadline;

private alias M = ModelPlatform;
private alias ModelMutex = MutexT!M;

/// `n` lockers each increment a protected counter `iterations` times.
private void counting(uint n, uint iterations, bool fiberFor1)(ref Scenario s)
{
    auto m = new ModelMutex;
    auto counter = new ModelCell!uint;
    s.each(n, (uint i) {
        s.thread({
            foreach (_; 0 .. iterations)
            {
                m.lock();
                assert(pins!M == 1, "holding a Mutex pins (SYK9)");
                counter.set(counter.get() + 1);
                m.unlock();
            }
            assert(pins!M == 0);
        }, testParker: fiberFor1 && i == 1);
    });
    s.finally_({
        // Reading in the final check: every thread has finished.
        assert(M.peek(*cast(ModelAtomic!ubyte*) m) == 0, "the mutex ends free with no bits set");
    });
}

@("sync.model.SYM.mutualExclusionTwoThreads")
@system unittest
{
    exploreAll(ModelOptions(), &counting!(2, 2, false));
}

@("sync.model.SYM.mutualExclusionWithAFiber")
@system unittest
{
    exploreAll(ModelOptions(spurious: 1), &counting!(2, 2, true));
}

@("sync.model.SYM6.threeLockersOneDesignation")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 2), &counting!(3, 1, false));
}

@("sync.model.SYH1.seededFault.releaseRelaxed")
@system unittest
{
    exploreExpectingFailure(ModelOptions(fault: Fault.releaseRelaxed), &counting!(2, 2, false));
}

@("sync.model.SYM6.seededFault.wakeDespiteDesignation")
@system unittest
{
    exploreExpectingFailure(ModelOptions(preemptionBound: 3, fault: Fault.wakeDespiteDesignation),
        &counting!(3, 2, false));
}

@("sync.model.SYM3.lockUntilTimesOutLeavingNoTrace")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto m = new ModelMutex;
        auto held = new ModelAtomic!uint;
        auto counter = new ModelCell!uint;
        s.thread({
            m.lock();
            M.store(*held, 1u);
            counter.set(1);
            m.unlock();
        });
        s.thread({
            awaitValue(*held, 1u);
            if (m.lockUntilTicks(Deadline(7)))
            {
                assert(counter.get() == 1);
                m.unlock();
            }
            assert(pins!M == 0, "a timeout leaves no pin");
        });
        s.thread({
            m.lock();
            m.unlock();
        });
        s.finally_({
            assert(M.peek(*cast(ModelAtomic!ubyte*) m) == 0,
                "a timeout leaves no trace beyond what SYP15 reconciles");
        });
    });
}

@("sync.model.SYM4.tryLockNeverParks")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto m = new ModelMutex;
        auto counter = new ModelCell!uint;
        s.each(2, (uint i) {
            s.thread({
                if (m.tryLock())
                {
                    counter.set(counter.get() + 1);
                    m.unlock();
                }
            });
        });
    });
}

@("sync.model.SYL2.otherBitsArePreserved")
@system unittest
{
    // The lock in bits 0–2 of a ushort; another thread toggles bit 8.
    alias Bits = LockBitsT!(M, ushort, 1, 2, 4);
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        auto word = new ModelAtomic!ushort;
        auto counter = new ModelCell!uint;
        s.each(2, (uint i) {
            s.thread({
                Bits.lock(*word);
                counter.set(counter.get() + 1);
                Bits.unlock(*word);
            });
        });
        s.thread({
            M.fetchOr(*word, cast(ushort) 0x100);
            M.fetchAnd(*word, cast(ushort) ~0x100);
            M.fetchOr(*word, cast(ushort) 0x100);
        });
        s.finally_({
            assert(M.peek(*word) == 0x100, "the caller's bit survives, the lock bits are clear");
        });
    });
}

// ---------------------------------------------------------------------------
// Compile-time checks (oracle 6).

@("sync.mutex.oracle6.sizesAttributesShared")
@safe nothrow @nogc
unittest
{
    static assert(Mutex.sizeof == 1);
    static assert(!__traits(compiles, { Mutex a; Mutex b = a; }));
    shared Mutex sm;
    sm.lock();
    assert(sm.tryLock() == false);
    sm.unlock();
    Mutex m;
    {
        auto g = m.guard();
        assert(!m.tryLock());
    }
    assert(m.tryLock());
    m.unlock();
    shared uint word = 0x8000_0000;
    alias LB = LockBits!(uint, 1, 2, 4);
    LB.lock(word);
    LB.unlock(word);
    assert(word == 0x8000_0000);
}

// ---------------------------------------------------------------------------
// Native stress (oracle 3).

private __gshared Mutex stressMutex;
private __gshared ulong stressCounter;

@("sync.native.mutexStress")
@system unittest
{
    import std.parallelism : totalCPUs;

    const n = totalCPUs * 2;
    enum iterations = 20_000;
    Thread[] ts;
    foreach (_; 0 .. n)
        ts ~= new Thread({
            foreach (k; 0 .. iterations)
            {
                if (k % 7 == 0)
                {
                    if (!stressMutex.lockUntil(MonoTime.currTime + 1.msecs))
                        continue;
                }
                else
                    stressMutex.lock();
                ++stressCounter;
                stressMutex.unlock();
            }
        }).start();
    foreach (t; ts)
        t.join();
    assert(stressCounter <= n * iterations);
    assert(stressCounter >= n * (iterations - iterations / 7));
}
