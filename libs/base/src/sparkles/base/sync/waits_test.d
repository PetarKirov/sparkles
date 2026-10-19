/**
Tests of `Semaphore`, the events, `Latch`, `Barrier` and the address wait:
oracle 1 scenarios for SYS1–SYS5, SYE1–SYE4, SYB1–SYB3 and SYW1–SYW3 with
their seeded faults, compile-time checks (oracle 6) and native stress
(oracle 3).
*/
module sparkles.base.sync.waits_test;

import core.thread : Thread;
import core.time : MonoTime, msecs;

import sparkles.base.sync.address_wait;
import sparkles.base.sync.barrier;
import sparkles.base.sync.event;
import sparkles.base.sync.interruptible_mutex : WaitStatus;
import sparkles.base.sync.latch;
import sparkles.base.sync.model;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.seam : Deadline;
import sparkles.base.sync.semaphore;

private alias M = ModelPlatform;

private size_t permitsOf(ref SemaphoreT!M s) @trusted => M.peek(*cast(ModelAtomic!size_t*) &s) / 2;
private bool peekSet(E)(ref E e) @trusted => (M.peek(*cast(ModelAtomic!ubyte*) &e) & 1) != 0;
private size_t peekCount(ref LatchT!M l) @trusted => M.peek(*cast(ModelAtomic!size_t*) &l) / 2;

// ---------------------------------------------------------------------------
// Semaphore (SYS1–SYS5).

/// `n` threads share `permits` permits; with one, the permit is a mutex.
private void sharing(uint n, size_t permits, bool timed, bool cancel)(ref Scenario s)
{
    auto sem = new SemaphoreT!M(permits);
    auto inside = new ModelAtomic!uint;
    auto counter = new ModelCell!uint;
    auto completed = new ModelAtomic!uint;
    s.each(n, (uint i) {
        s.thread({
            WaitStatus r = WaitStatus.ok;
            if (timed && i == 0)
                r = sem.acquireTicks(Deadline(3), false);
            else if (cancel && i == 0)
                r = sem.acquireTicks(Deadline.never, true);
            else
                sem.acquire();
            if (r != WaitStatus.ok)
                return;
            assert(M.fetchAdd!(Order.relaxed)(*inside, 1u) < permits, "no more holders than permits (SYS4)");
            static if (permits == 1)
                counter.set(counter.get() + 1); // the release orders it (SYH1)
            M.fetchAdd!(Order.relaxed)(*inside, uint.max); // -1
            M.fetchAdd!(Order.relaxed)(*completed, 1u);
            sem.release();
        }, testParker: cancel && i == 0);
    });
    s.finally_({
        // SYS4: every permit taken was given back, so the count is whole
        // again and no handoff is outstanding.
        assert(permitsOf(*sem) == permits, "every permit is back (SYS4)");
        assert(M.peek(*cast(ModelAtomic!size_t*) sem) % 2 == 0, "no parked bit with nobody parked");
    });
}

@("sync.model.SYS.oneSharedPermit")
@system unittest
{
    exploreAll(ModelOptions(), &sharing!(2, 1, false, false));
}

@("sync.model.SYS.threeThreadsTwoPermits")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), &sharing!(3, 2, false, false));
}

@("sync.model.SYS4.timeoutKeepsTheBalance")
@system unittest
{
    exploreAll(ModelOptions(), &sharing!(2, 1, true, false));
}

@("sync.model.SYS4.cancellationKeepsTheBalance")
@system unittest
{
    exploreAll(ModelOptions(cancels: 1), &sharing!(2, 1, false, true));
}

@("sync.model.SYH1.seededFault.semaphoreReleaseRelaxed")
@system unittest
{
    exploreExpectingFailure(ModelOptions(fault: Fault.releaseRelaxed), &sharing!(2, 1, false, false));
}

@("sync.model.SYS3.releaseHandsOffBeforeRaisingTheCount")
@system unittest
{
    // W waits on an empty semaphore; R releases two permits. W is handed
    // one (or takes it), and exactly one is left: available plus handed off
    // equals the initial count plus released minus completed acquisitions.
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto sem = new SemaphoreT!M;
        auto data = new ModelCell!uint;
        s.thread({
            sem.acquire();
            assert(data.get() == 1, "a handed-off permit carries the release's edge (SYH1)");
        });
        s.thread({
            data.set(1);
            sem.release(2);
        });
        s.finally_({
            assert(permitsOf(*sem) == 1, "two released, one acquired (SYS4)");
        });
    });
}

@("sync.model.SYI1.nonInterruptibleAcquireIgnoresCancellation")
@system unittest
{
    // A fiber in a non-interruptible acquire receives a cancellation; it
    // neither returns early nor loops, and acquires once the permit is
    // released (SYI1).
    exploreAll(ModelOptions(cancels: 1), (ref Scenario s) {
        auto sem = new SemaphoreT!M;
        s.thread({
            sem.acquire();
        }, testParker: true);
        s.thread({
            sem.release();
        });
        s.finally_({
            assert(permitsOf(*sem) == 0);
        });
    });
}

@("sync.semaphore.oracle6.sizeAndCopies")
@safe unittest
{
    static assert(Semaphore.sizeof == size_t.sizeof, "SYS1");
    static assert(!__traits(compiles, { Semaphore a; Semaphore b = a; }), "SYA4");
}

@("sync.model.SYS5.anOverflowingReleaseFails")
@system unittest
{
    exploreExpectingFailure(ModelOptions(), (ref Scenario s) {
        auto sem = new SemaphoreT!M(SemaphoreT!M.maxPermits);
        s.thread({ sem.release(); });
    });
}

// ---------------------------------------------------------------------------
// Events (SYE1–SYE4).

@("sync.model.SYE2.manualResetReleasesEveryWaiter")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        auto e = new ManualResetEventT!M;
        auto data = new ModelCell!uint;
        s.each(2, (uint i) {
            s.thread({
                e.wait();
                assert(data.get() == 1, "set happens before every wait it ends (SYH1)");
                assert(e.isSet, "a manual-reset event stays set (SYE2)");
            });
        });
        s.thread({
            data.set(1);
            e.set();
        });
    });
}

@("sync.model.SYH1.seededFault.eventSetRelaxed")
@system unittest
{
    exploreExpectingFailure(ModelOptions(fault: Fault.releaseRelaxed), (ref Scenario s) {
        auto e = new ManualResetEventT!M;
        auto data = new ModelCell!uint;
        s.thread({
            e.wait();
            assert(data.get() == 1);
        });
        s.thread({
            data.set(1);
            e.set();
        });
    });
}

@("sync.model.SYE3.autoResetReleasesOneWaiterPerSignal")
@system unittest
{
    // Two waiters with deadlines and one set: exactly one consumes the
    // signal, or nobody does and the event stays set (SYE3, SYE4).
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto e = new AutoResetEventT!M;
        auto woken = new ModelAtomic!uint;
        s.each(2, (uint i) {
            s.thread({
                if (e.waitTicks(Deadline(3), false) == WaitStatus.ok)
                    M.fetchAdd!(Order.relaxed)(*woken, 1u);
            });
        });
        s.thread({
            e.set();
        });
        s.finally_({
            const w = M.peek(*woken);
            assert(w + (peekSet(*e) ? 1 : 0) == 1, "one signal is consumed once or kept (SYE3)");
        });
    });
}

@("sync.model.SYE4.cancelledAutoResetWaiterConsumesNothing")
@system unittest
{
    exploreAll(ModelOptions(cancels: 1), (ref Scenario s) {
        auto e = new AutoResetEventT!M;
        auto woken = new ModelAtomic!uint;
        s.thread({
            if (e.waitTicks(Deadline.never, true) == WaitStatus.ok)
                M.fetchAdd!(Order.relaxed)(*woken, 1u);
        }, testParker: true);
        s.thread({
            e.set();
        });
        s.finally_({
            assert(M.peek(*woken) + (peekSet(*e) ? 1 : 0) == 1,
                "a selected waiter reports success; a cancelled one consumes nothing (SYE4)");
        });
    });
}

@("sync.model.SYE3.setOfASetEventDoesNothing")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto e = new AutoResetEventT!M;
        s.thread({
            e.set();
            e.set();
            assert(e.tryWait());
            assert(!e.tryWait(), "two sets leave one signal (SYE3)");
        });
    });
}

@("sync.event.oracle6.sizes")
@safe unittest
{
    static assert(ManualResetEvent.sizeof == 1 && AutoResetEvent.sizeof == 1, "SYE1");
    static assert(!__traits(compiles, { AutoResetEvent a; AutoResetEvent b = a; }), "SYA4");
}

@("sync.model.SYE2.aSetBegunBeforeAResetNeverReleasesALaterWaiter")
@system unittest
{
    // W1 parks; S sets; R sees the set, resets, then waits. S's wake may be
    // late, but R's wait began after the only reset and no set follows it.
    exploreAll(ModelOptions(preemptionBound: 2), (ref Scenario s) {
        auto e = new ManualResetEventT!M;
        s.thread({
            cast(void) e.waitTicks(Deadline(4), false);
        });
        s.thread({
            e.set();
        });
        s.thread({
            while (!e.isSet)
                M.yieldThread();
            e.reset();
            assert(e.waitTicks(Deadline(4), false) == WaitStatus.timedOut,
                "a wait begun after the only reset was released (SYE2)");
        });
    });
}

// ---------------------------------------------------------------------------
// Latch (SYB3).

@("sync.model.SYB3.latchReleasesOnceAndStaysOpen")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        auto l = new LatchT!M(2);
        auto a = new ModelCell!uint;
        auto b = new ModelCell!uint;
        s.thread({
            l.wait();
            // Every count-down happens before the wait it ends (SYH1).
            assert(a.get() == 1 && b.get() == 1);
            l.wait(); // stays open
        });
        s.thread({
            a.set(1);
            l.countDown();
        });
        s.thread({
            b.set(1);
            l.countDown();
        });
    });
}

@("sync.model.SYH1.seededFault.latchCountDownRelaxed")
@system unittest
{
    exploreExpectingFailure(ModelOptions(fault: Fault.releaseRelaxed), (ref Scenario s) {
        auto l = new LatchT!M(1);
        auto a = new ModelCell!uint;
        s.thread({
            l.wait();
            assert(a.get() == 1);
        });
        s.thread({
            a.set(1);
            l.countDown();
        });
    });
}

@("sync.model.SYB3.timeoutLeavesTheCount")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto l = new LatchT!M(1);
        s.thread({
            const r = l.waitTicks(Deadline(2), false);
            assert(r == WaitStatus.ok || r == WaitStatus.timedOut);
        });
        s.thread({
            l.countDown();
        });
        s.finally_({
            assert(peekCount(*l) == 0);
        });
    });
}

@("sync.model.SYB3.countingBelowZeroFails")
@system unittest
{
    exploreExpectingFailure(ModelOptions(), (ref Scenario s) {
        auto l = new LatchT!M(1);
        s.thread({
            l.countDown();
            l.countDown();
        });
    });
}

// ---------------------------------------------------------------------------
// Barrier (SYB1, SYB2).

@("sync.model.SYB1.generationsNeverMix")
@system unittest
{
    // Two parties, two generations: each writes its slot before arriving
    // and reads the other's after; exactly one leader per generation.
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        auto b = new BarrierT!M(2);
        auto slots = new ModelCell!uint[](2);
        auto leaders = new ModelAtomic!uint;
        s.each(2, (uint i) {
            s.thread({
                foreach (gen; 1 .. 3)
                {
                    slots[i].set(gen);
                    if (b.arriveAndWait())
                        M.fetchAdd!(Order.relaxed)(*leaders, 1u);
                    assert(slots[1 - i].get() >= gen,
                        "every arrival of the generation happens before its release (SYB1, SYH1)");
                    // A party of the next generation is not released by this one.
                    if (b.arriveAndWait())
                        M.fetchAdd!(Order.relaxed)(*leaders, 1u);
                }
            });
        });
        s.finally_({
            assert(M.peek(*leaders) == 4, "one leader per generation (SYB1)");
        });
    });
}

@("sync.model.SYH1.seededFault.barrierArrivalRelaxed")
@system unittest
{
    exploreExpectingFailure(ModelOptions(fault: Fault.releaseRelaxed), (ref Scenario s) {
        auto b = new BarrierT!M(2);
        auto a = new ModelCell!uint;
        s.thread({
            a.set(1);
            cast(void) b.arriveAndWait();
        });
        s.thread({
            cast(void) b.arriveAndWait();
            assert(a.get() == 1);
        });
    });
}

@("sync.model.SYB2.withdrawnArrivalDoesNotCount")
@system unittest
{
    // Both parties arrive with deadlines: either the generation completes
    // with both present, or neither is released; a timed-out arrival is
    // withdrawn, so the barrier ends with nobody counted.
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto b = new BarrierT!M(2);
        auto ok = new ModelAtomic!uint;
        auto leaders = new ModelAtomic!uint;
        s.each(2, (uint i) {
            s.thread({
                const a = b.arrive(Deadline(3), false);
                if (a)
                    M.fetchAdd!(Order.relaxed)(*ok, 1u);
                if (a.leader)
                    M.fetchAdd!(Order.relaxed)(*leaders, 1u);
            });
        });
        s.finally_({
            const n = M.peek(*ok);
            assert(n == 0 || n == 2, "a generation completes only with every party present (SYB2)");
            assert(M.peek(*leaders) == (n == 2 ? 1 : 0));
            assert((M.peek(*cast(ModelAtomic!ulong*) b) & uint.max) == 0, "no arrival is left counted");
        });
    });
}

@("sync.model.SYB2.cancelledArrivalIsWithdrawn")
@system unittest
{
    exploreAll(ModelOptions(cancels: 1), (ref Scenario s) {
        auto b = new BarrierT!M(2);
        auto ok = new ModelAtomic!uint;
        s.thread({
            if (b.arrive(Deadline.never, true))
                M.fetchAdd!(Order.relaxed)(*ok, 1u);
        }, testParker: true);
        s.thread({
            if (b.arrive(Deadline(3), false))
                M.fetchAdd!(Order.relaxed)(*ok, 1u);
        });
        s.finally_({
            const n = M.peek(*ok);
            assert(n == 0 || n == 2, "a generation completes only with every party present (SYB2)");
        });
    });
}

@("sync.model.SYI2.aCancellationLosingToCompletionStaysPending")
@system unittest
{
    // The last party completes the generation before the cancelled party
    // withdraws: the arrival succeeds, and its cancellation is not settled.
    exploreAll(ModelOptions(cancels: 1), (ref Scenario s) {
        auto b = new BarrierT!M(2);
        s.thread({
            if (b.arrive(Deadline.never, true))
                assert(testParkerStats(threadId).settles == 0,
                    "a successful arrival settled its cancellation (SYI2, SYI3)");
            else
                assert(testParkerStats(threadId).settles == 1);
        }, testParker: true);
        s.thread({
            cast(void) b.arrive(Deadline(3), false);
        });
    });
}

// ---------------------------------------------------------------------------
// The address wait (SYW1–SYW3).

@("sync.model.SYW.waitAndWake")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto word = new ModelAtomic!uint;
        auto data = new ModelCell!uint;
        s.thread({
            while (M.load!(Order.acquire)(*word) == 0)
                AddressWait!M.waitWhile(*word, 0u);
            assert(data.get() == 1);
        });
        s.thread({
            data.set(1);
            M.store!(Order.release)(*word, 1u);
            cast(void) AddressWait!M.wakeOne(*word);
        });
    });
}

@("sync.model.SYW1.aWordThatDiffersNeverParks")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto word = new ModelAtomic!ushort(cast(ushort) 7);
        s.thread({
            AddressWait!M.waitWhile(*word, cast(ushort) 6);
            assert(testParkerStats(threadId).parks == 0, "no park when the word differs (SYW1)");
        }, testParker: true);
    });
}

@("sync.model.SYW3.aStoreAloneWakesNobody")
@system unittest
{
    // Without a wake the waiter stays parked: the explorer reports the
    // schedule in which it parked first as a deadlock.
    exploreExpectingFailure(ModelOptions(), (ref Scenario s) {
        auto word = new ModelAtomic!ulong;
        s.thread({
            AddressWait!M.waitWhile(*word, 0UL);
        });
        s.thread({
            M.store!(Order.release)(*word, 1UL);
        });
    });
}

@("sync.model.SYW2.wakesReturnExactCounts")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        auto word = new ModelAtomic!ubyte;
        auto woken = new ModelAtomic!uint;
        s.each(2, (uint i) {
            s.thread({
                while (M.load!(Order.acquire)(*word) == 0)
                    AddressWait!M.waitWhile(*word, cast(ubyte) 0);
            });
        });
        s.thread({
            M.store!(Order.release)(*word, cast(ubyte) 1);
            uint total;
            foreach (_; 0 .. 2)
            {
                const n = AddressWait!M.wakeAll(*word);
                assert(n <= 2);
                total += n;
            }
            M.store(*woken, total);
        });
        s.finally_({
            assert(M.peek(*woken) <= 2, "no waiter is counted twice (SYW2)");
        });
    });
}

@("sync.model.SYW1.timeoutOnlyIfParkedAndNotWoken")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto word = new ModelAtomic!uint;
        s.thread({
            const r = AddressWait!M.waitWhileTicks(*word, 0u, Deadline(2), false);
            assert(r == WaitStatus.ok || r == WaitStatus.timedOut);
        });
        s.thread({
            M.store!(Order.release)(*word, 1u);
            cast(void) AddressWait!M.wakeAll(*word);
        });
    });
}

@("sync.model.SYW1.aWakeEndsTheWaitWithTheWordUnchanged")
@system unittest
{
    // The word never changes: a wait that read it again after the wake
    // would park again, and the explorer would report it blocked forever.
    exploreAll(ModelOptions(), (ref Scenario s) {
        auto word = new ModelAtomic!uint;
        s.thread({
            AddressWait!M.waitWhile(*word, 0u);
        });
        s.thread({
            while (AddressWait!M.wakeOne(*word) == 0)
                M.yieldThread();
        });
    });
}

// ---------------------------------------------------------------------------
// Native stress (oracle 3).

@("sync.native.semaphoreStress")
@system unittest
{
    __gshared Semaphore sem;
    static shared uint inside, maxInside;
    static shared ulong acquisitions;
    sem = Semaphore(3);
    Thread[] ts;
    foreach (i; 0 .. 8)
        ts ~= new Thread({
            import core.atomic : atomicFetchAdd, atomicFetchSub, atomicLoad, cas;

            foreach (j; 0 .. 2_000)
            {
                if (j % 7 == 0)
                {
                    if (sem.acquireUntil(MonoTime.currTime + 1.msecs) != WaitStatus.ok)
                        continue;
                }
                else
                    sem.acquire();
                const n = atomicFetchAdd(inside, 1) + 1;
                uint m = atomicLoad(maxInside);
                while (n > m && !cas(&maxInside, m, n))
                    m = atomicLoad(maxInside);
                atomicFetchSub(inside, 1);
                atomicFetchAdd(acquisitions, 1);
                sem.release();
            }
        }).start();
    foreach (t; ts)
        t.join();
    import core.atomic : atomicLoad;

    assert(atomicLoad(maxInside) <= 3, "never more holders than permits");
    assert(sem.available == 3, "every permit is back");
    assert(atomicLoad(acquisitions) > 0);
}

@("sync.native.eventsLatchBarrierStress")
@system unittest
{
    enum parties = 6, rounds = 300;
    __gshared Barrier barrier;
    __gshared Latch done;
    __gshared AutoResetEvent token;
    __gshared ManualResetEvent go;
    static shared uint[parties] slots;
    static shared uint leaders, tokens;
    barrier = Barrier(parties);
    done = Latch(parties);
    Thread[] ts;
    foreach (i; 0 .. parties)
        ts ~= new Thread(((uint id) => () {
            import core.atomic : atomicFetchAdd, atomicLoad, atomicStore;

            go.wait();
            foreach (r; 1 .. rounds + 1)
            {
                atomicStore(slots[id], r);
                if (barrier.arriveAndWait())
                    atomicFetchAdd(leaders, 1);
                foreach (k; 0 .. parties)
                    assert(atomicLoad(slots[k]) >= r, "a generation releases only after every arrival");
                cast(void) barrier.arriveAndWait();
                if (id == 0)
                    token.set();
                else if (token.waitUntil(MonoTime.currTime + 1.msecs) == WaitStatus.ok)
                    atomicFetchAdd(tokens, 1);
            }
            done.countDown();
        })(i)).start();
    go.set();
    done.wait();
    foreach (t; ts)
        t.join();
    import core.atomic : atomicLoad;

    assert(atomicLoad(leaders) == rounds, "one leader per generation");
    assert(atomicLoad(tokens) <= rounds, "no auto-reset signal is consumed twice");
    assert(done.isOpen);
}

@("sync.native.addressWaitStress")
@system unittest
{
    static shared uint word;
    static shared uint seen;
    Thread[] ts;
    foreach (i; 0 .. 4)
        ts ~= new Thread({
            import core.atomic : atomicFetchAdd, atomicLoad;

            uint v;
            while ((v = atomicLoad(word)) < 1_000)
                waitWhile(word, v);
            atomicFetchAdd(seen, 1);
        }).start();
    foreach (n; 1 .. 1_001)
    {
        import core.atomic : atomicStore;

        atomicStore(word, n);
        cast(void) wakeAll(word);
    }
    foreach (t; ts)
        t.join();
    import core.atomic : atomicLoad;

    assert(atomicLoad(seen) == 4);
}

@("sync.platform.oracle6.initStateTrustsOnlyTheNativeWord")
@safe unittest
{
    import sparkles.base.sync.platform : initState;

    // A platform's own word type constructs with its own attributes: an
    // unsafe constructor stays unsafe through `initState` (SYA2).
    static struct UnsafeWord
    {
        size_t v;
        this(size_t x) @system { v = x; }
    }

    static assert(!__traits(compiles, () @safe { UnsafeWord w; initState(w, size_t(1)); }));
    static assert(__traits(compiles, () @safe { shared size_t w; initState(w, size_t(1)); }));
}
