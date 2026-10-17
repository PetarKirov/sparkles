/**
Tests of `InterruptibleMutex`, `Condition`, `Once` and `Guarded`: oracle 1
scenarios for SYJ1–SYJ5, SYC1–SYC9, SYO1–SYO6 and SYG1–SYG4, compile-time
checks (oracle 6) and native stress (oracle 3).
*/
module sparkles.base.sync.primitives_test;

import core.thread : Thread;
import core.time : MonoTime, msecs;

import sparkles.base.sync.condition;
import sparkles.base.sync.guarded;
import sparkles.base.sync.interruptible_mutex;
import sparkles.base.sync.model;
import sparkles.base.sync.mutex;
import sparkles.base.sync.once;
import sparkles.base.sync.parker : pins;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.seam : Deadline;

private alias M = ModelPlatform;

// ---------------------------------------------------------------------------
// InterruptibleMutex (SYJ1–SYJ5).

@("sync.model.SYJ.mutualExclusionAndHandoff")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto m = new InterruptibleMutexT!M;
        auto counter = new ModelCell!uint;
        s.each(2, (uint i) {
            s.thread({
                foreach (_; 0 .. 2)
                {
                    auto a = m.lock();
                    assert(a, "an uncancelled lock acquires");
                    assert(pins!M == 0, "holding an InterruptibleMutex does not pin (SYJ4)");
                    counter.set(counter.get() + 1);
                }
            }, testParker: i == 1);
        });
    });
}

@("sync.model.SYJ3.cancellationRacingAGrant")
@system unittest
{
    exploreAll(ModelOptions(cancels: 1), (ref Scenario s) {
        auto m = new InterruptibleMutexT!M;
        auto held = new ModelAtomic!uint;
        auto counter = new ModelCell!uint;
        s.thread({
            auto a = m.lock();
            M.store(*held, 1u);
            counter.set(1);
        });
        s.thread({
            awaitValue(*held, 1u);
            auto a = m.lock();
            // Cancelled with nothing held, or granted despite the request.
            if (a)
                assert(counter.get() == 1);
            else
                assert(a.status == WaitStatus.cancelled && !a.guard.holds);
        }, testParker: true);
        s.finally_({
            assert(M.peek(*cast(ModelAtomic!ubyte*) m) == 0, "no lock leaks to a cancelled waiter");
        });
    });
}

// ---------------------------------------------------------------------------
// Condition (SYC1–SYC9).

/// A consumer waits for a flag a producer sets under the lock and notifies.
private void handshake(bool all, bool fiber)(ref Scenario s)
{
    auto m = new MutexT!M;
    auto c = new ConditionT!M;
    auto flag = new ModelCell!uint;
    enum uint consumers = all ? 2 : 1;
    s.each(consumers, (uint i) {
        s.thread({
            auto g = m.guard();
            while (flag.get() == 0)
                c.wait(g);
            assert(pins!M == 1, "the wait returns holding the lock (SYC2)");
        }, testParker: fiber && i == 0);
    });
    s.thread({
        auto g = m.guard();
        flag.set(1);
        static if (all)
            cast(void) c.notifyAll();
        else
            cast(void) c.notifyOne();
    });
    s.finally_({
        assert(M.peek(*cast(ModelAtomic!size_t*) c) == 0, "the condition ends with no waiters");
        assert(M.peek(*cast(ModelAtomic!ubyte*) m) == 0, "the mutex ends free");
    });
}

@("sync.model.SYC2.notifyOne")
@system unittest
{
    exploreAll(ModelOptions(), &handshake!(false, false));
}

@("sync.model.SYC2.notifyOneToAFiber")
@system unittest
{
    exploreAll(ModelOptions(spurious: 1), &handshake!(false, true));
}

@("sync.model.SYC6.notifyAllMorphsOntoTheMutex")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), &handshake!(true, false));
}

@("sync.model.SYC3.timeoutReturnsHoldingTheLock")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto m = new MutexT!M;
        auto c = new ConditionT!M;
        auto data = new ModelCell!uint;
        s.thread({
            auto g = m.guard();
            const r = c.waitTicks(g, Deadline(4), false);
            assert(r == WaitStatus.ok || r == WaitStatus.timedOut);
            data.set(data.get() + 1); // the lock is held either way
        });
        s.thread({
            auto g = m.guard();
            data.set(data.get() + 1);
            cast(void) c.notifyOne();
        });
    });
}

@("sync.model.SYC7.cancellationDuringReacquisitionIsNotObserved")
@system unittest
{
    // A fiber waiting interruptibly on an InterruptibleMutex is notified or
    // cancelled; either way it returns holding the mutex.
    exploreAll(ModelOptions(cancels: 1), (ref Scenario s) {
        auto m = new InterruptibleMutexT!M;
        auto c = new ConditionT!M;
        auto flag = new ModelCell!uint;
        auto waiting = new ModelAtomic!uint;
        s.thread({
            auto a = m.acquire(Deadline.never, false);
            M.store(*waiting, 1u);
            const r = c.waitTicks(a.guard, Deadline.never, true);
            assert(r == WaitStatus.ok || r == WaitStatus.cancelled);
            flag.set(flag.get() + 1); // held after a cancellation too (SYC3)
        }, testParker: true);
        s.thread({
            awaitValue(*waiting, 1u);
            auto a = m.acquire(Deadline.never, false);
            flag.set(flag.get() + 1);
            cast(void) c.notifyAll();
        });
        s.finally_({
            assert(M.peek(*cast(ModelAtomic!ubyte*) m) == 0);
        });
    });
}

@("sync.model.SYC6.notifyAllOnAFreeHandoffLock")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        auto m = new InterruptibleMutexT!M;
        auto c = new ConditionT!M;
        auto waiting = new ModelAtomic!uint;
        auto woken = new ModelCell!uint;
        s.each(2, (uint i) {
            s.thread({
                auto a = m.acquire(Deadline.never, false);
                M.fetchAdd(*waiting, 1u);
                c.wait(a.guard);
                woken.set(woken.get() + 1);
            });
        });
        s.thread({
            awaitValue(*waiting, 2u);
            // Notify with the lock free: the woken waiter is handed it, the
            // other is moved onto its queue. A waiter counted but not yet
            // enqueued is selected by a later round.
            uint selected;
            while (selected < 2)
            {
                selected += c.notifyAll();
                M.yieldThread();
            }
            assert(selected == 2);
        });
    });
}

// ---------------------------------------------------------------------------
// Once (SYO1–SYO6).

@("sync.model.SYO2.initRunsOnce")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto o = new OnceT!M;
        auto runs = new ModelCell!uint;
        s.each(3, (uint i) {
            s.thread({
                o.call(() { runs.set(runs.get() + 1); });
                assert(runs.get() == 1, "every caller returns after the one init completed");
            });
        });
    });
}

@("sync.model.SYO4.exceptionLetsAnotherCallerRetry")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto o = new OnceT!M;
        auto attempts = new ModelCell!uint;
        s.each(2, (uint i) {
            s.thread({
                try
                    o.call(() {
                        const n = attempts.get() + 1;
                        attempts.set(n);
                        if (n == 1)
                            throw new Exception("first attempt fails");
                    });
                catch (Exception)
                    return;
                assert(attempts.get() == 2, "the retry sees the failed attempt's writes");
            });
        });
    });
}

// ---------------------------------------------------------------------------
// Guarded (SYG1–SYG4) and compile-time checks (oracle 6).

private struct Counted
{
    int n;
}

@("sync.guarded.SYG.payloadThroughTheGuard")
@safe unittest
{
    Guarded!Counted g;
    {
        auto guard = g.lock();
        guard.get.n = 5;
        assert(!g.tryLock().holds, "the guard holds the mutex");
    }
    assert(g.lock().get.n == 5);
    static assert(!__traits(compiles, Guarded!(int[])), "SYG3: a slice is not contained");
    static assert(!__traits(compiles, Guarded!(int*)), "SYG3: a pointer is not contained");
    static assert(!__traits(compiles, Guarded!Object), "SYG3: a class reference is not contained");
    static assert(__traits(compiles, Guarded!string), "immutable indirections are contained");
}

@("sync.condition.SYC9.waitThroughEveryGuard")
@system unittest
{
    Mutex m;
    Condition c;
    InterruptibleMutex im;
    Guarded!int gi;
    shared ulong word;
    alias LB = LockBits!(ulong, 1, 2, 4);
    // Each wait times out and returns holding its lock.
    const soon = MonoTime.currTime + 1.msecs;
    {
        auto g = m.guard();
        assert(!c.waitUntil(g, soon));
        assert(!m.tryLock());
    }
    {
        auto a = im.lock();
        assert(c.waitInterruptible(a.guard, soon) == WaitStatus.timedOut);
    }
    {
        auto g = gi.lock();
        assert(!c.waitUntil(g, soon));
    }
    {
        auto g = LB.guard(word);
        assert(!c.waitUntil(g, soon));
    }
    assert(c.notifyOne() == false, "no waiters: one load (SYC8)");
}

@("sync.oracle6.sizesAndCopies")
@safe nothrow @nogc
unittest
{
    static assert(Condition.sizeof == size_t.sizeof);
    static assert(InterruptibleMutex.sizeof == 1);
    static assert(Once.sizeof == 1);
    static assert(!__traits(compiles, { Condition a; Condition b = a; }));
    static assert(!__traits(compiles, { Once a; Once b = a; }));
    static assert(!__traits(compiles, { InterruptibleMutex a; InterruptibleMutex b = a; }));
    static assert(!__traits(hasMember, InterruptibleMutex, "unlock"));
}

// ---------------------------------------------------------------------------
// Native (oracle 3).

private __gshared Mutex queueLock;
private __gshared Condition queueReady;
private __gshared int queued, consumed;

@("sync.native.conditionProducerConsumer")
@system unittest
{
    enum producers = 4, consumers = 4, items = 2_000;
    Thread[] ts;
    foreach (_; 0 .. consumers)
        ts ~= new Thread({
            foreach (__; 0 .. items)
            {
                auto g = queueLock.guard();
                while (queued == 0)
                    queueReady.wait(g);
                --queued;
                ++consumed;
            }
        }).start();
    foreach (_; 0 .. producers)
        ts ~= new Thread({
            foreach (__; 0 .. items)
            {
                auto g = queueLock.guard();
                ++queued;
                queueReady.notifyOne();
            }
        }).start();
    foreach (t; ts)
        t.join();
    assert(consumed == consumers * items && queued == 0);
}

private __gshared Once onceForNative;
private __gshared int onceRuns;

@("sync.native.onceUnderContention")
@system unittest
{
    Thread[] ts;
    foreach (_; 0 .. 8)
        ts ~= new Thread({
            onceForNative.call(() { Thread.sleep(1.msecs); ++onceRuns; });
            assert(onceRuns == 1);
        }).start();
    foreach (t; ts)
        t.join();
    assert(onceRuns == 1 && onceForNative.isComplete);
}

private __gshared InterruptibleMutex imNative;
private __gshared ulong imCounter;

@("sync.native.interruptibleMutexStress")
@system unittest
{
    enum n = 8, iterations = 5_000;
    Thread[] ts;
    foreach (_; 0 .. n)
        ts ~= new Thread({
            foreach (__; 0 .. iterations)
            {
                auto a = imNative.lock();
                assert(a);
                ++imCounter;
            }
        }).start();
    foreach (t; ts)
        t.join();
    assert(imCounter == n * iterations);
}

// ---------------------------------------------------------------------------
// Rows of testing.md beyond the basic scenarios.

@("sync.model.SYM8.handedTheLockWithinTheBound")
@system unittest
{
    import sparkles.base.sync.mutex : starvationBoundFor;

    // A parked waiter against two bargers that keep relocking: it is woken
    // at most starvationBound times as the designated waker, then handed
    // the lock (SYM8).
    exploreAll(ModelOptions(preemptionBound: 2, maxExecutions: 300_000), (ref Scenario s) {
        auto m = new MutexT!M;
        auto held = new ModelAtomic!uint;
        s.thread({
            awaitValue(*held, 1u);
            m.lock();
            m.unlock();
            const wakes = testParkerStats(threadId).commits;
            assert(wakes <= starvationBoundFor!M + 1, "the waiter was not handed the lock in time");
        }, testParker: true);
        s.each(2, (uint i) {
            s.thread({
                foreach (k; 0 .. 2)
                {
                    m.lock();
                    if (i == 0 && k == 0)
                        M.store(*held, 1u);
                    m.unlock();
                }
            });
        });
    });
}

@("sync.model.SYI4.protectedRegionDoesNotObserveCancellation")
@system unittest
{
    exploreAll(ModelOptions(cancels: 1), (ref Scenario s) {
        auto m = new InterruptibleMutexT!M;
        auto held = new ModelAtomic!uint;
        auto release = new ModelAtomic!uint;
        s.thread({
            auto a = m.lock();
            M.store(*held, 1u);
            awaitValue(*release, 1u);
        });
        s.thread({
            awaitValue(*held, 1u);
            setProtectedRegion(true);
            M.store(*release, 1u);
            auto a = m.lock();
            assert(a, "inside a protected region the wait acquires (SYI4)");
            setProtectedRegion(false);
        }, testParker: true);
    });
}

@("sync.model.SYO5.errorPoisons")
@system unittest
{
    exploreExpectingFailure(ModelOptions(), (ref Scenario s) {
        auto o = new OnceT!M;
        s.thread({
            try
                o.call(() { throw new Error("init failed"); });
            catch (Error)
            {
            }
            // A later call fails an assertion: the Once is poisoned.
            o.call(() {});
        });
    });
}

@("sync.model.SYO6.waiterTimeoutLeavesInitRunning")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto o = new OnceT!M;
        auto runs = new ModelCell!uint;
        auto inInit = new ModelAtomic!uint;
        s.thread({
            o.call(() {
                M.store(*inInit, 1u);
                runs.set(runs.get() + 1);
            });
        });
        s.thread({
            awaitValue(*inInit, 1u);
            const r = o.callTicks(() { runs.set(runs.get() + 1); }, Deadline(3), false);
            assert(r == WaitStatus.ok || r == WaitStatus.timedOut);
        });
        s.finally_({
            assert(runs.peek() == 1, "init ran once; a timed-out waiter did not run it again");
        });
    });
}

@("sync.model.SYC5.notifyBetweenEnqueueAndRelease")
@system unittest
{
    // The notifier runs while the waiter is enqueued but still holds the
    // lock: the waiter is moved onto its own lock's queue, and its release
    // wakes it or hands it the lock; it returns holding the lock once.
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto m = new MutexT!M;
        auto c = new ConditionT!M;
        auto data = new ModelCell!uint;
        s.thread({
            auto g = m.guard();
            c.wait(g);
            data.set(data.get() + 1);
        });
        s.thread({
            // Spin until the waiter is enqueued, without taking the lock.
            while (!c.notifyOne())
                M.yieldThread();
        });
    });
}

@("sync.model.SYK9.conditionWaitDropsThePinForItsSleep")
@system unittest
{
    // A fiber holding a Mutex waits on a condition: it suspends (its own
    // parker sleeps), and its pin is back with the lock on return.
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto m = new MutexT!M;
        auto c = new ConditionT!M;
        auto flag = new ModelCell!uint;
        s.thread({
            auto g = m.guard();
            assert(pins!M == 1);
            bool waited;
            while (flag.get() == 0)
            {
                c.wait(g);
                waited = true;
            }
            assert(pins!M == 1, "the pin is restored with the lock (SYK9)");
            if (waited)
                assert(testParkerStats(threadId).parks > 0, "the fiber's own parker slept");
        }, testParker: true);
        s.thread({
            auto g = m.guard();
            flag.set(1);
            cast(void) c.notifyAll();
        });
    });
}

@("sync.guarded.SYG3.moveOnlyContainedPayload")
@safe unittest
{
    import sparkles.base.buffer : UniqueBuffer;

    // An owning buffer is the payload @contained exists for: move-only, its
    // storage reachable only through `return scope` members.
    @contained static struct Owned
    {
        UniqueBuffer!(int, 4) items;
    }

    Guarded!Owned g;
    {
        auto guard = g.lock();
        guard.get.items ~= 7;
    }
    assert(g.lock().get.items[] == [7]);
    InterruptibleGuarded!Owned ig;
    {
        auto a = ig.lock();
        assert(a && a.guard.holds);
        assert(ig.tryLock().status == WaitStatus.unavailable, "a held lock's try form (SYJ6)");
    }
    assert(ig.tryLock(), "a free lock's try form acquires");
}
