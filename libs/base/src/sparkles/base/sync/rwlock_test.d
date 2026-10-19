/**
Tests of `RwLock`: oracle 1 scenarios for SYR1–SYR7 with a seeded fault,
compile-time checks (oracle 6) and native stress (oracle 3).
*/
module sparkles.base.sync.rwlock_test;

import core.thread : Thread;
import core.time : MonoTime, msecs;

import sparkles.base.sync.model;
import sparkles.base.sync.parker : pins;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.rwlock;
import sparkles.base.sync.seam : Deadline;

private alias M = ModelPlatform;
private alias ModelRw = RwLockT!M;

private size_t stateOf(ref ModelRw l) @trusted => M.peek(*cast(ModelAtomic!size_t*) &l);

/// The lock word read by a simulated thread: a step the model schedules.
private size_t wordOf(ref ModelRw l) @trusted => M.load!(Order.relaxed)(*cast(ModelAtomic!size_t*) &l);

/// A lock whose drain key, with `colocated`, shares its main key's bucket (SYP15).
private ModelRw* newRw(bool colocated) @trusted
{
    auto l = new ModelRw;
    if (colocated)
    {
        shareBucket(cast(size_t) l + 1, cast(size_t) l);
        assert(M.bucketOf(cast(size_t) l + 1) == M.bucketOf(cast(size_t) l));
    }
    return l;
}

/**
Writers increment a protected counter and readers read it: a reader that
overlapped a writer, or a writer another writer, is a data race the model
reports (SYR2).
*/
private void readersAndWriters(uint readers, uint writers, bool timed)(ref Scenario s)
{
    auto l = new ModelRw;
    auto counter = new ModelCell!uint;
    auto writes = new ModelAtomic!uint;
    s.each(readers + writers, (uint i) {
        s.thread({
            if (i < writers)
            {
                if (timed && i == 0)
                {
                    if (!l.lockTicks(Deadline(3)))
                        return;
                }
                else
                    l.lock();
                assert(pins!M == 1, "holding an RwLock pins (SYK9)");
                counter.set(counter.get() + 1);
                M.fetchAdd!(Order.relaxed)(*writes, 1u);
                l.unlock();
            }
            else
            {
                if (timed && i == writers)
                {
                    if (!l.lockSharedTicks(Deadline(3)))
                        return;
                }
                else
                    l.lockShared();
                cast(void) counter.get();
                l.unlockShared();
            }
            assert(pins!M == 0);
        });
    });
    s.finally_({
        assert(counter.peek() == M.peek(*writes));
        assert(stateOf(*l) == 0, "the lock ends free with no bits set");
    });
}

@("sync.model.SYR2.oneWriterOneReader")
@system unittest
{
    exploreAll(ModelOptions(), &readersAndWriters!(1, 1, false));
}

@("sync.model.SYR2.twoWritersOneReader")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), &readersAndWriters!(1, 2, false));
}

@("sync.model.SYR3.twoReadersOneWriter")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), &readersAndWriters!(2, 1, false));
}

@("sync.model.SYR7.timeoutsLeaveNoTrace")
@system unittest
{
    exploreAll(ModelOptions(), &readersAndWriters!(1, 1, true));
}

@("sync.model.SYR7.timedWriterBehindReaders")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), &readersAndWriters!(2, 1, true));
}

@("sync.model.SYH1.seededFault.rwLockReleaseRelaxed")
@system unittest
{
    exploreExpectingFailure(ModelOptions(fault: Fault.releaseRelaxed), &readersAndWriters!(1, 1, false));
}


/// U holds upgradable, R holds shared, W queues for exclusive, U upgrades,
/// R releases: U acquires exclusive before W (SYR4).
private void upgradeOutranksAQueuedWriter(bool colocated)(ref Scenario s)
{
    auto l = newRw(colocated);
    auto order = new ModelCell!uint;
    auto step = new ModelAtomic!uint;
    s.thread({
        l.lockUpgradable();
        M.store(*step, 1u);
        awaitValue(*step, 3u);
        l.upgrade();
        assert(order.get() == 0, "the upgrade comes before the queued writer (SYR4)");
        order.set(1);
        l.unlock();
    });
    s.thread({
        awaitValue(*step, 1u);
        l.lockShared();
        M.store(*step, 2u);
        awaitValue(*step, 3u);
        l.unlockShared();
    });
    s.thread({
        awaitValue(*step, 2u);
        M.store(*step, 3u);
        l.lock();
        // The writer may have arrived after U's whole exclusive section.
        order.set(order.get() + 10);
        l.unlock();
    });
    s.finally_({
        assert(order.peek() == 11);
        assert(stateOf(*l) == 0);
    });
}

@("sync.model.SYR4.upgradeOutranksAQueuedWriter")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), &upgradeOutranksAQueuedWriter!false);
}


/// An upgrade that times out keeps upgradable mode (SYR4).
private void upgradeTimeoutKeepsUpgradable(bool colocated)(ref Scenario s)
{
    auto l = newRw(colocated);
    auto step = new ModelAtomic!uint;
    s.thread({
        l.lockUpgradable();
        awaitValue(*step, 1u);
        if (!l.upgradeTicks(Deadline(2)))
        {
            // Still upgradable: a new reader may share it, a writer may not.
            assert(!l.tryLock());
            l.unlockUpgradable();
        }
        else
            l.unlock();
    });
    s.thread({
        l.lockShared();
        M.store(*step, 1u);
        l.unlockShared();
    });
    s.finally_({
        assert(stateOf(*l) == 0);
    });
}

@("sync.model.SYR4.upgradeTimeoutKeepsUpgradable")
@system unittest
{
    exploreAll(ModelOptions(), &upgradeTimeoutKeepsUpgradable!false);
}

@("sync.model.SYR7.nextUpgradableWaiterAcquires")
@system unittest
{
    // U1 and U2 queue for upgradable mode behind a writer; U1 releases
    // without upgrading, and U2 acquires (SYR7).
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        auto l = new ModelRw;
        auto held = new ModelAtomic!uint;
        s.thread({
            l.lock();
            M.store(*held, 1u);
            l.unlock();
        });
        s.each(2, (uint i) {
            s.thread({
                awaitValue(*held, 1u);
                l.lockUpgradable();
                l.unlockUpgradable();
            });
        });
        s.finally_({
            assert(stateOf(*l) == 0);
        });
    });
}

@("sync.model.SYR7.lastReaderWakesAPendingUpgrade")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        auto l = new ModelRw;
        auto data = new ModelCell!uint;
        auto step = new ModelAtomic!uint;
        s.each(2, (uint i) {
            s.thread({
                l.lockShared();
                cast(void) data.get();
                M.fetchAdd(*step, 1u);
                l.unlockShared();
            });
        });
        s.thread({
            l.lockUpgradable();
            awaitValue(*step, 2u);
            l.upgrade();
            // Every shared release happens before the upgrade (SYH1).
            data.set(1);
            l.downgrade();
            l.unlockShared();
        });
        s.finally_({
            assert(stateOf(*l) == 0);
        });
    });
}

@("sync.model.SYR2.downgradesLetReadersIn")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        auto l = new ModelRw;
        auto data = new ModelCell!uint;
        auto held = new ModelAtomic!uint;
        s.thread({
            l.lock();
            data.set(1);
            M.store(*held, 1u);
            l.downgradeToUpgradable();
            cast(void) data.get();
            l.downgradeUpgradable();
            cast(void) data.get();
            l.unlockShared();
        });
        s.thread({
            awaitValue(*held, 1u);
            l.lockShared();
            assert(data.get() == 1);
            l.unlockShared();
        });
        s.finally_({
            assert(stateOf(*l) == 0);
        });
    });
}

@("sync.rwlock.oracle6.sizeAndCopies")
@safe unittest
{
    static assert(RwLock.sizeof == size_t.sizeof, "SYR1");
    static assert(!__traits(compiles, { RwLock a; RwLock b = a; }), "SYA4");
    static assert(!__traits(compiles, { RwGuard!NativePlatform a; RwGuard!NativePlatform b = a; }), "SYA4");
}

@("sync.rwlock.guards")
@system unittest
{
    // A second holder is always another thread: taking shared mode while
    // holding the lock is the recursion SYR6 forbids.
    __gshared RwLock l;
    static void elsewhere(void function() f)
    {
        auto t = new Thread(f);
        t.start();
        t.join();
    }
    {
        auto r = l.read();
        elsewhere({
            auto r2 = l.read();
            assert(!l.tryLock(), "readers exclude a writer");
        });
    }
    {
        auto u = l.upgradableRead();
        elsewhere({
            assert(l.tryLockShared(), "upgradable mode admits readers");
            l.unlockShared();
            assert(!l.tryLockUpgradable(), "one upgradable holder");
        });
        u.upgrade();
        assert(u.mode == RwMode.exclusive);
        u.downgrade();
        assert(u.mode == RwMode.shared_);
    }
    {
        auto w = l.write();
        elsewhere({ assert(!l.tryLockShared(), "a writer excludes readers"); });
    }
    assert(l.tryLock());
    l.unlock();
}

// ---------------------------------------------------------------------------
// Native stress (oracle 3).

@("sync.native.rwLockStress")
@system unittest
{
    __gshared RwLock l;
    static shared ulong counter;
    static shared uint writersInside, readersInside;
    Thread[] ts;
    foreach (i; 0 .. 8)
        ts ~= new Thread(((uint id) => () {
            import core.atomic : atomicFetchAdd, atomicFetchSub, atomicLoad;

            foreach (j; 0 .. 3_000)
            {
                const pick = (id + j) % 10;
                if (pick < 2)
                {
                    if (pick == 1 && !l.lockUntil(MonoTime.currTime + 1.msecs))
                        continue;
                    if (pick == 0)
                        l.lock();
                    assert(atomicFetchAdd(writersInside, 1) == 0 && atomicLoad(readersInside) == 0);
                    atomicFetchAdd(counter, 1);
                    atomicFetchSub(writersInside, 1);
                    l.unlock();
                }
                else if (pick == 2)
                {
                    l.lockUpgradable();
                    atomicFetchAdd(readersInside, 1);
                    assert(atomicLoad(writersInside) == 0);
                    atomicFetchSub(readersInside, 1);
                    if (j % 3 == 0 && l.upgradeUntil(MonoTime.currTime + 1.msecs))
                    {
                        assert(atomicFetchAdd(writersInside, 1) == 0 && atomicLoad(readersInside) == 0);
                        atomicFetchAdd(counter, 1);
                        atomicFetchSub(writersInside, 1);
                        l.unlock();
                    }
                    else
                        l.unlockUpgradable();
                }
                else
                {
                    l.lockShared();
                    atomicFetchAdd(readersInside, 1);
                    assert(atomicLoad(writersInside) == 0, "a reader never overlaps a writer");
                    atomicFetchSub(readersInside, 1);
                    l.unlockShared();
                }
            }
        })(i)).start();
    foreach (t; ts)
        t.join();
    import core.atomic : atomicLoad;

    assert(atomicLoad(counter) > 0);
    assert(l.tryLock(), "the lock ends free");
    l.unlock();
}

@("sync.model.SYH1.everyReaderBeforeAGrantedWriter")
@system unittest
{
    // W1 holds the lock while R1, R2 and W2 queue. W1's release grants the
    // readers; the first to leave releases plainly, the last runs the pass
    // that grants W2. W2 must see both readers' reads ordered before its
    // write: shared release before exclusive acquisition (§13).
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        auto l = new ModelRw;
        auto data = new ModelCell!uint;
        auto held = new ModelAtomic!uint;
        s.thread({
            l.lock();
            M.store(*held, 1u);
            M.yieldThread();
            l.unlock();
        });
        s.each(2, (uint i) {
            s.thread({
                awaitValue(*held, 1u);
                l.lockShared();
                cast(void) data.get();
                l.unlockShared();
            });
        });
        s.thread({
            awaitValue(*held, 1u);
            l.lock();
            data.set(1);
            l.unlock();
        });
    });
}

@("sync.model.SYR2.anUpgradeCannotSplitARelease")
@system unittest
{
    // U holds upgradable; a timed writer T and then a reader R queue. T
    // times out and its pass grants R shared mode as U upgrades: the
    // upgrade waits for the pass, so U and R never hold incompatible modes.
    exploreAll(ModelOptions(preemptionBound: 2), (ref Scenario s) {
        auto l = new ModelRw;
        auto data = new ModelCell!uint;
        auto held = new ModelAtomic!uint;
        auto queued = new ModelAtomic!uint;
        s.thread({
            l.lockUpgradable();
            M.store(*held, 1u);
            awaitValue(*queued, 1u);
            l.upgrade();
            data.set(1);
            l.unlock();
        });
        s.thread({
            awaitValue(*held, 1u);
            if (l.lockTicks(Deadline(2)))
                l.unlock();
        });
        s.thread({
            awaitValue(*held, 1u);
            M.store(*queued, 1u);
            l.lockShared();
            cast(void) data.get();
            l.unlockShared();
        });
        s.finally_({
            assert(stateOf(*l) == 0);
        });
    });
}


/// A timed writer D sets the writer bit and drains R's shared mode; W queues
/// behind it. D times out as R leaves by a plain release: the pass that gives
/// the writer bit back must still grant W (SYR7).
private void drainTimeoutAsTheLastReaderLeaves(bool colocated)(ref Scenario s)
{
    auto l = newRw(colocated);
    auto held = new ModelAtomic!uint;
    s.thread({
        l.lockShared();
        M.store(*held, 1u);
        M.yieldThread();
        l.unlockShared();
    });
    s.thread({
        awaitValue(*held, 1u);
        if (l.lockTicks(Deadline(2)))
            l.unlock();
    });
    s.thread({
        awaitValue(*held, 1u);
        l.lock();
        l.unlock();
    });
    s.finally_({
        assert(stateOf(*l) == 0);
    });
}

@("sync.model.SYR7.drainTimeoutAsTheLastReaderLeaves")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 2), &drainTimeoutAsTheLastReaderLeaves!false);
}

@("sync.model.SYP15.aDrainKeyInItsMainKeysBucket")
@system unittest
{
    // The drain scenarios with the drain key in the main key's bucket: a
    // drainer's record must not keep the main key's parked bit set, and the
    // last reader's wake must still reach the drainer (SYP15).
    exploreAll(ModelOptions(preemptionBound: 1), &upgradeOutranksAQueuedWriter!true);
    exploreAll(ModelOptions(), &upgradeTimeoutKeepsUpgradable!true);
    exploreAll(ModelOptions(preemptionBound: 2), &drainTimeoutAsTheLastReaderLeaves!true);
}

@("sync.model.SYP15.theLastMainWaiterClearsTheParkedBit")
@system unittest
{
    // U upgrades, waiting on the drain key for R; W times out of the main
    // queue. Once W has left, no main-key record remains: the parked bit
    // must be clear, though U's record shares the bucket (SYP15).
    enum size_t parkedBit = 4;
    static foreach (colocated; [false, true])
        exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
            auto l = newRw(colocated);
            auto upgradableHeld = new ModelAtomic!uint;
            auto sharedHeld = new ModelAtomic!uint;
            auto writerGone = new ModelAtomic!uint;
            s.thread({
                l.lockUpgradable();
                M.store(*upgradableHeld, 1u);
                awaitValue(*sharedHeld, 1u);
                l.upgrade();
                l.unlock();
            });
            s.thread({
                awaitValue(*upgradableHeld, 1u);
                l.lockShared();
                M.store(*sharedHeld, 1u);
                awaitValue(*writerGone, 1u);
                l.unlockShared();
            });
            s.thread({
                awaitValue(*sharedHeld, 1u);
                // U has taken the writer bit: it drains R on the drain key.
                while (!(wordOf(*l) & 1))
                    M.yieldThread();
                assert(!l.lockTicks(Deadline(2)), "U holds upgradable mode throughout");
                assert(!(wordOf(*l) & parkedBit), "no main-key waiter remains (SYP15)");
                M.store(*writerGone, 1u);
            });
            s.finally_({
                assert(stateOf(*l) == 0);
            });
        });
}

@("sync.model.SYR5.thePassSkipsASecondUpgradableWaiter")
@system unittest
{
    // Behind a writer, two upgradable waiters and a reader queue, in any
    // order; each upgradable holder stays until the reader is in. A pass
    // that stopped at the second upgradable waiter would leave the reader
    // queued behind it while the first waits for the reader: a deadlock.
    exploreAll(ModelOptions(preemptionBound: 0), (ref Scenario s) {
        auto l = new ModelRw;
        auto held = new ModelAtomic!uint;
        auto readerIn = new ModelAtomic!uint;
        s.thread({
            l.lock();
            M.store(*held, 1u);
            // A test-parker waiter prepares its sleep under the bucket
            // lock, once queued: the release's pass then sees all three.
            foreach (id; 1 .. 4)
                while (testParkerStats(id).prepares == 0)
                    M.yieldThread();
            l.unlock();
        });
        s.each(2, (uint i) {
            s.thread({
                awaitValue(*held, 1u);
                l.lockUpgradable();
                awaitValue(*readerIn, 1u);
                l.unlockUpgradable();
            }, testParker: true);
        });
        s.thread({
            awaitValue(*held, 1u);
            l.lockShared();
            M.store(*readerIn, 1u);
            l.unlockShared();
        }, testParker: true);
        s.finally_({
            assert(stateOf(*l) == 0);
        });
    });
}

@("sync.model.SYK9.aReleaseStaysPinnedThroughTheBucket")
@system unittest
{
    // A fiber releasing a contended lock may wait for the bucket: still
    // holding the mode, it must wait on the thread parker, never yield.
    static foreach (mode; 0 .. 3)
        exploreAll(ModelOptions(preemptionBound: 3), (ref Scenario s) {
            auto l = new ModelRw;
            auto held = new ModelAtomic!uint;
            s.thread({
                static if (mode == 0)
                    l.lock();
                else static if (mode == 1)
                    l.lockShared();
                else
                    l.lockUpgradable();
                M.store(*held, 1u);
                const before = testParkerStats(threadId).yields;
                static if (mode == 0)
                    l.unlock();
                else static if (mode == 1)
                    l.unlockShared();
                else
                    l.unlockUpgradable();
                assert(testParkerStats(threadId).yields == before, "a release yielded holding its mode (SYK9)");
            }, testParker: true);
            s.thread({
                awaitValue(*held, 1u);
                l.lock();
                l.unlock();
            });
        });
}

@("sync.model.SYR6.downgradesWithoutTheModeFail")
@system unittest
{
    exploreExpectingFailure(ModelOptions(), (ref Scenario s) {
        auto l = new ModelRw;
        s.thread({ l.downgrade(); });
    });
    exploreExpectingFailure(ModelOptions(), (ref Scenario s) {
        auto l = new ModelRw;
        s.thread({ l.downgradeToUpgradable(); });
    });
    exploreExpectingFailure(ModelOptions(), (ref Scenario s) {
        auto l = new ModelRw;
        s.thread({ l.downgradeUpgradable(); });
    });
}
