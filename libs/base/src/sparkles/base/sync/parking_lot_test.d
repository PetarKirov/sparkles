/**
Tests of the parking lot: oracle 1 scenarios for SYP1–SYP15, SYK1–SYK8, SYI3
and SYF2's fallback (testing.md § the seam and the parking lot), each with
its seeded fault, and native tests (oracle 3).
*/
module sparkles.base.sync.parking_lot_test;

import core.thread : Thread;
import core.time : msecs;

import sparkles.base.sync.model;
import sparkles.base.sync.parker;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.seam : Deadline;

private alias M = ModelPlatform;

/// Two keys in one bucket and one key in another (SYP1).
private size_t[3] keys() @safe pure nothrow
{
    size_t[3] k;
    k[0] = 0x1000;
    foreach (size_t c; 0x1001 .. 0x100_0000)
        if (bucketIndex(c) == bucketIndex(k[0]))
        {
            k[1] = c;
            break;
        }
    foreach (size_t c; 0x2000 .. 0x100_0000)
        if (bucketIndex(c) != bucketIndex(k[0]))
        {
            k[2] = c;
            break;
        }
    return k;
}

private enum ubyte proto = 1, otherProto = 2;

/// Blocks until `word` holds `v` (the model's non-spinning wait).
private void await(T)(ref ModelAtomic!T word, T v) @trusted
{
    awaitValue(word, v);
}

// ---------------------------------------------------------------------------
// SYP2: a park racing an unpark across the validation point is never stranded.

private void validatedEnqueue(ref Scenario s)
{
    auto flag = new ModelAtomic!uint;
    const k = keys()[0];
    s.thread({
        const r = park!M(k, ParkOptions(proto), (ref const LockedKey!M lk) => M.load(*flag) == 0);
        assert(r.outcome == ParkOutcome.unparked || r.outcome == ParkOutcome.invalid);
    });
    s.thread({
        M.store(*flag, 1u);
        unparkOne!M(k, proto, (ref const LockedKey!M lk, UnparkResult r) => UnparkDecision(0));
    });
}

@("sync.model.SYP2.validatedEnqueue")
@system unittest
{
    exploreAll(ModelOptions(), &validatedEnqueue);
}

@("sync.model.SYP2.seededFault.validateOutsideLock")
@system unittest
{
    exploreExpectingFailure(ModelOptions(fault: Fault.validateOutsideLock), &validatedEnqueue);
}

@("sync.model.SYP10.seededFault.unlockSkipsWake")
@system unittest
{
    exploreExpectingFailure(ModelOptions(fault: Fault.unlockSkipsWake), &validatedEnqueue);
}

// ---------------------------------------------------------------------------
// SYP5: a deadline racing a committed unpark returns unparked with its token,
// and the record leaves the queue exactly once.

private void timeoutRace(ref Scenario s)
{
    const k = keys()[0];
    auto saw = new ModelAtomic!uint;
    auto got = new ModelAtomic!uint;
    s.thread({
        const r = park!M(k, ParkOptions(proto, deadline: Deadline(10)),
            (ref const LockedKey!M lk) => true);
        assert(r.outcome == ParkOutcome.unparked || r.outcome == ParkOutcome.timedOut);
        M.store(*got, r.outcome == ParkOutcome.unparked ? cast(uint) r.token : 1u);
    });
    s.thread({
        unparkOne!M(k, proto, (ref const LockedKey!M lk, UnparkResult r) {
            M.store(*saw, r.unparked + 1);
            return UnparkDecision(7);
        });
    });
    s.finally_({
        // The unparker dequeued the record exactly when the park says so.
        const unparked = M.peek(*saw) == 2;
        assert(unparked == (M.peek(*got) == 7), "the outcome disagrees with the unparker");
    });
}

@("sync.model.SYP5.timeoutRacingUnpark")
@system unittest
{
    exploreAll(ModelOptions(), &timeoutRace);
}

@("sync.model.SYP5.seededFault.timeoutIgnoresToken")
@system unittest
{
    exploreExpectingFailure(ModelOptions(fault: Fault.timeoutIgnoresToken), &timeoutRace);
}

@("sync.model.SYP5.cancellationRacingUnpark")
@system unittest
{
    // The test parker: its sleep may be cancelled, and it is not exact.
    exploreAll(ModelOptions(preemptionBound: 1, cancels: 1), (ref Scenario s) {
        const k = keys()[0];
        auto saw = new ModelAtomic!uint;
        auto got = new ModelAtomic!uint;
        s.thread({
            const r = park!M(k, ParkOptions(proto, interruptible: true),
                (ref const LockedKey!M lk) => true);
            M.store(*got, r.outcome == ParkOutcome.unparked ? cast(uint) r.token
                : r.outcome == ParkOutcome.cancelled ? 1u : 2u);
            const st = testParkerStats(threadId);
            // SYI3: settle exactly when the park ended cancelled.
            assert(st.settles == (r.outcome == ParkOutcome.cancelled ? 1 : 0));
        }, testParker: true);
        s.thread({
            unparkOne!M(k, proto, (ref const LockedKey!M lk, UnparkResult r) {
                M.store(*saw, r.unparked + 1);
                return UnparkDecision(7);
            });
        });
        s.finally_({
            const unparked = M.peek(*saw) == 2;
            assert(unparked == (M.peek(*got) == 7));
            assert(M.peek(*got) != 2, "an outcome the park cannot have");
        });
    });
}

// ---------------------------------------------------------------------------
// SYP4: injected spurious returns never end a park; SYK2: a stale delivery
// resumes a still-queued waiter, which re-prepares under the lock.

@("sync.model.SYP4.spuriousReturnsNeverEndAPark")
@system unittest
{
    foreach (useTestParker; [false, true])
        exploreAll(ModelOptions(preemptionBound: 1, spurious: 1), (ref Scenario s) {
            const k = keys()[0];
            auto ready = new ModelAtomic!uint;
            s.thread({
                const r = park!M(k, ParkOptions(proto), (ref const LockedKey!M lk) {
                    M.store(*ready, 1u);
                    return true;
                });
                assert(r.outcome == ParkOutcome.unparked && r.token == 5);
            }, useTestParker);
            s.thread({
                await(*ready, 1u);
                unparkOne!M(k, proto, (ref const LockedKey!M lk, UnparkResult r) => UnparkDecision(5));
            });
        });
}

@("sync.model.SYK2.staleDeliveryReprepares")
@system unittest
{
    // T0 parks twice on one key; T1 unparks it twice. A delivery of the first
    // wake may land in the second park, which must sleep again.
    exploreAll(ModelOptions(), (ref Scenario s) {
        const k = keys()[0];
        auto parked = new ModelAtomic!uint;
        s.thread({
            foreach (i; 0 .. 2)
            {
                const r = park!M(k, ParkOptions(proto), (ref const LockedKey!M lk) {
                    M.fetchAdd(*parked, 1u);
                    return true;
                });
                assert(r.outcome == ParkOutcome.unparked && r.token == i + 1);
            }
        }, testParker: true);
        s.thread({
            foreach (uint i; 0 .. 2)
            {
                await(*parked, i + 1);
                unparkOne!M(k, proto, (ref const LockedKey!M lk, UnparkResult r) {
                    assert(r.unparked == 1);
                    return UnparkDecision(i + 1);
                });
            }
        });
        s.finally_({
            const st = testParkerStats(0);
            assert(st.prepares >= 2 && st.commits == 2);
        });
    });
}

// ---------------------------------------------------------------------------
// SYP3: an unpark from beforeSleep wakes a waiter enqueued before it.

@("sync.model.SYP3.beforeSleepUnparks")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        const k = keys();
        auto first = new ModelAtomic!uint;
        s.thread({
            const r = park!M(k[0], ParkOptions(proto), (ref const LockedKey!M lk) {
                M.store(*first, 1u);
                return true;
            });
            assert(r.outcome == ParkOutcome.unparked && r.token == 3);
        });
        s.thread({
            await(*first, 1u);
            // Park on another key; once enqueued, wake the first waiter.
            const r = park!M(k[2], ParkOptions(proto, deadline: Deadline(5)),
                (ref const LockedKey!M lk) => true, () {
                    const u = unparkOne!M(k[0], proto,
                        (ref const LockedKey!M lk, UnparkResult r) => UnparkDecision(3));
                    assert(u.unparked == 1);
                });
            assert(r.outcome == ParkOutcome.timedOut);
        });
    });
}

// ---------------------------------------------------------------------------
// SYP6: waiters on one key are unparked in enqueue order; SYK6 across parkers.

@("sync.model.SYP6.fifoAcrossParkers")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        const k = keys()[0];
        auto tickets = new ModelAtomic!uint;
        auto order = new ModelAtomic!uint[2];
        s.each(2, (uint i) {
            s.thread({
                uint mine;
                const r = park!M(k, ParkOptions(proto), (ref const LockedKey!M lk) {
                    mine = M.fetchAdd(*tickets, 1u);
                    return true;
                });
                assert(r.outcome == ParkOutcome.unparked);
                // The n-th unpark wakes the n-th enqueued record.
                assert(r.token == mine, "unparked out of enqueue order");
            }, testParker: i == 1);
        });
        s.thread({
            await(*tickets, 2u);
            foreach (uint n; 0 .. 2)
                unparkOne!M(k, proto, (ref const LockedKey!M lk, UnparkResult r) {
                    assert(r.unparked == 1 && r.haveMore == (n == 0));
                    return UnparkDecision(n);
                });
        });
    });
}

// ---------------------------------------------------------------------------
// SYP1 + SYP7: colliding keys are independent; callback arguments are exact.

@("sync.model.SYP1.collidingKeysAreIndependent")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        const k = keys();
        auto parked = new ModelAtomic!uint;
        s.each(2, (uint i) {
            s.thread({
                const r = park!M(k[i], ParkOptions(proto), (ref const LockedKey!M lk) {
                    M.fetchAdd(*parked, 1u);
                    return true;
                });
                assert(r.outcome == ParkOutcome.unparked && r.token == 10 + i);
            });
        });
        s.thread({
            await(*parked, 2u);
            foreach (uint i; 0 .. 2)
                unparkOne!M(k[i], proto, (ref const LockedKey!M lk, UnparkResult r) {
                    assert(r.unparked == 1 && !r.haveMore);
                    assert(lk.hasQueued == false);
                    return UnparkDecision(10 + i);
                });
        });
    });
}

// ---------------------------------------------------------------------------
// SYP8: requeued records keep their order and do not wake; a stale timeout of
// a requeued record is spurious and resolves under its new key (SYP14).

@("sync.model.SYP8.requeueKeepsOrder")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        const k = keys();
        auto tickets = new ModelAtomic!uint;
        s.each(2, (uint i) {
            s.thread({
                uint mine;
                const r = park!M(k[0], ParkOptions(proto, deadline: i == 0 ? Deadline(3) : Deadline.never),
                    (ref const LockedKey!M lk) {
                        mine = M.fetchAdd(*tickets, 1u);
                        return true;
                    });
                if (r.outcome == ParkOutcome.timedOut)
                    return; // timed out before the requeue
                assert(r.outcome == ParkOutcome.unparked);
                assert(r.token == 100 + mine, "a requeued record lost its order");
            }, testParker: i == 0);
        });
        s.thread({
            await(*tickets, 2u);
            ubyte toProto = otherProto;
            const q = unparkRequeue!M(k[0], proto, k[2], toProto,
                (ref const LockedKey!M f, ref const LockedKey!M t) => RequeueOp.requeueAll,
                (ref const LockedKey!M f, ref const LockedKey!M t, UnparkResult r) {
                    assert(r.unparked == 0 && !r.haveMore);
                    return UnparkDecision(0);
                });
            // Whoever is still queued was moved; wake them from the new key in order.
            uint woken;
            while (woken < q.requeued)
            {
                const u = unparkOne!M(k[2], otherProto, (ref const LockedKey!M lk, UnparkResult r)
                    => UnparkDecision(100 + (q.requeued == 2 ? woken : 1)));
                woken += u.unparked;
            }
        });
    });
}

@("sync.model.SYP8.unparkOneRequeueRest")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        const k = keys();
        auto parked = new ModelAtomic!uint;
        auto requeued = new ModelAtomic!uint;
        s.each(2, (uint i) {
            s.thread({
                const r = park!M(k[0], ParkOptions(proto), (ref const LockedKey!M lk) {
                    M.fetchAdd(*parked, 1u);
                    return true;
                });
                assert(r.outcome == ParkOutcome.unparked);
            });
        });
        s.thread({
            await(*parked, 2u);
            ubyte toProto = otherProto;
            const q = unparkRequeue!M(k[0], proto, k[1], toProto,
                (ref const LockedKey!M f, ref const LockedKey!M t) => RequeueOp.unparkOneRequeueRest,
                (ref const LockedKey!M f, ref const LockedKey!M t, UnparkResult r) {
                    assert(r.unparked == 1 && r.requeued == 1 && !r.haveMore);
                    assert(t.hasQueued, "the moved record is on the destination key");
                    return UnparkDecision(1);
                });
            assert(q.unparked == 1 && q.requeued == 1);
            unparkOne!M(k[1], otherProto, (ref const LockedKey!M lk, UnparkResult r) {
                assert(r.unparked == 1);
                return UnparkDecision(2);
            });
        });
    });
}

// ---------------------------------------------------------------------------
// SYP9: a filter's wake, skip and stop select exactly the records it accepted;
// with more records than one round, deliveries come in rounds.

@("sync.model.SYP9.filterSelects")
@system unittest
{
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        const k = keys()[0];
        auto parked = new ModelAtomic!uint;
        auto woken = new ModelAtomic!uint;
        s.each(3, (uint i) {
            s.thread({
                const r = park!M(k, ParkOptions(proto, parkToken: i, deadline: i == 1 ? Deadline(9) : Deadline.never),
                    (ref const LockedKey!M lk) {
                        M.fetchAdd(*parked, 1u);
                        return true;
                    });
                if (i == 1)
                    assert(r.outcome == ParkOutcome.timedOut, "the filter skipped it");
                else
                {
                    assert(r.outcome == ParkOutcome.unparked && r.token == 42);
                    M.fetchAdd(*woken, 1u);
                }
            }, testParker: i == 2);
        });
        s.thread({
            await(*parked, 3u);
            const u = unparkFilter!M(k, proto, (size_t t) => t == 1 ? FilterOp.skip : FilterOp.wake,
                (ref const LockedKey!M lk, UnparkResult r) {
                    assert(r.unparked == 2);
                    return UnparkDecision(42);
                });
            assert(u.unparked == 2);
        });
    });
}

@("sync.model.SYP9.unparkAllInRounds")
@system unittest
{
    // With one wake per round under the model, a second waiter is dequeued but
    // uncommitted while the first is delivered; it must not return early.
    exploreAll(ModelOptions(preemptionBound: 1), (ref Scenario s) {
        const k = keys()[0];
        auto parked = new ModelAtomic!uint;
        s.each(2, (uint i) {
            s.thread({
                const r = park!M(k, ParkOptions(proto, deadline: Deadline(4)), (ref const LockedKey!M lk) {
                    M.fetchAdd(*parked, 1u);
                    return true;
                });
                assert(r.outcome == ParkOutcome.unparked || r.outcome == ParkOutcome.timedOut);
                if (r.outcome == ParkOutcome.unparked)
                    assert(r.token == 8);
            }, testParker: i == 1);
        });
        s.thread({
            await(*parked, 2u);
            unparkAll!M(k, proto, (ref const LockedKey!M lk, UnparkResult r) => UnparkDecision(8));
        });
    });
}

// ---------------------------------------------------------------------------
// SYP14: meeting a record of another protocol fails an assertion.

@("sync.model.SYP14.otherProtocolFailsAnAssertion")
@system unittest
{
    exploreExpectingFailure(ModelOptions(), (ref Scenario s) {
        const k = keys()[0];
        auto parked = new ModelAtomic!uint;
        s.thread({
            cast(void) park!M(k, ParkOptions(proto, deadline: Deadline(2)), (ref const LockedKey!M lk) {
                M.store(*parked, 1u);
                return true;
            });
        });
        s.thread({
            await(*parked, 1u);
            unparkOne!M(k, otherProto, (ref const LockedKey!M lk, UnparkResult r) => UnparkDecision(0));
        });
    });
}

// ---------------------------------------------------------------------------
// SYP15: a designation registers the woken record; the waiter retires it.

@("sync.model.SYP15.designationRegistersAndRetires")
@system unittest
{
    exploreAll(ModelOptions(), (ref Scenario s) {
        const k = keys()[0];
        auto parked = new ModelAtomic!uint;
        s.thread({
            const r = park!M(k, ParkOptions(proto), (ref const LockedKey!M lk) {
                M.store(*parked, 1u);
                return true;
            });
            assert(r.outcome == ParkOutcome.unparked);
            assert(callerRegistered!M(), "a designated record is registered");
            retire!M(k, (ref const LockedKey!M lk) {
                assert(!lk.hasRegistration, "retired under the bucket lock");
            });
        }, testParker: true);
        s.thread({
            await(*parked, 1u);
            unparkOne!M(k, proto, (ref const LockedKey!M lk, UnparkResult r) {
                assert(!lk.hasRegistration);
                return UnparkDecision(1, designate: true);
            });
        });
    });
}

// ---------------------------------------------------------------------------
// SYK8: a delivery through the record is reported.

@("sync.model.SYK8.seededFault.deliveryThroughRecord")
@system unittest
{
    exploreExpectingFailure(ModelOptions(spurious: 1, fault: Fault.deliveryThroughRecord), (ref Scenario s) {
        const k = keys()[0];
        auto parked = new ModelAtomic!uint;
        s.thread({
            const r = park!M(k, ParkOptions(proto), (ref const LockedKey!M lk) {
                M.store(*parked, 1u);
                return true;
            });
            assert(r.outcome == ParkOutcome.unparked);
        }, testParker: true);
        s.thread({
            await(*parked, 1u);
            unparkOne!M(k, proto, (ref const LockedKey!M lk, UnparkResult r) => UnparkDecision(1));
        });
    });
}

// ---------------------------------------------------------------------------
// SYH2: everything the unparker did before the unpark happens before the
// park's return; the seeded fault weakens the thread parker's commit.

private void publication(ref Scenario s)
{
    const k = keys()[0];
    auto parked = new ModelAtomic!uint;
    auto data = new ModelCell!uint;
    s.thread({
        const r = park!M(k, ParkOptions(proto), (ref const LockedKey!M lk) {
            M.store!(Order.relaxed)(*parked, 1u);
            return true;
        });
        assert(r.outcome == ParkOutcome.unparked);
        assert(data.get() == 99);
    });
    s.thread({
        awaitValue!(Order.relaxed)(*parked, 1u);
        data.set(99);
        unparkOne!M(k, proto, (ref const LockedKey!M lk, UnparkResult r) => UnparkDecision(1));
    });
}

@("sync.model.SYH2.unparkPublishes")
@system unittest
{
    exploreAll(ModelOptions(), &publication);
}

@("sync.model.SYH2.seededFault.commitRelaxed")
@system unittest
{
    exploreExpectingFailure(ModelOptions(fault: Fault.commitRelaxed), &publication);
}

// ---------------------------------------------------------------------------
// SYP13: the bucket lock under contention, with a fiber that yields; the
// seeded fault drops the bucket unlock's wake.

private void bucketContention(ref Scenario s)
{
    const k = keys();
    // Three lockers of one bucket; each wakes nobody, so only the bucket lock
    // is contended. A lost bucket wake leaves a thread asleep forever.
    s.each(3, (uint i) {
        s.thread({
            unparkOne!M(k[i % 2], proto, (ref const LockedKey!M lk, UnparkResult r) => UnparkDecision(0));
        });
    });
}

@("sync.model.SYP13.bucketLock")
@system unittest
{
    exploreAll(ModelOptions(), &bucketContention);
}

@("sync.model.SYP13.seededFault.bucketUnlockSkipsWake")
@system unittest
{
    exploreExpectingFailure(ModelOptions(preemptionBound: 3, fault: Fault.bucketUnlockSkipsWake),
        &bucketContention);
}

// ---------------------------------------------------------------------------
// SYF2: the portable fallback's waiter returns only after delivery released its mutex.

@("sync.model.SYF2.portableFallback")
@system unittest
{
    alias PM = PortableModelPlatform;
    exploreAll(ModelOptions(), (ref Scenario s) {
        const k = keys()[0];
        auto parked = new ModelAtomic!uint;
        s.thread({
            const r = park!PM(k, ParkOptions(proto, deadline: Deadline(6)), (ref const LockedKey!PM lk) {
                PM.store(*parked, 1u);
                return true;
            });
            assert(r.outcome == ParkOutcome.unparked || r.outcome == ParkOutcome.timedOut);
        });
        s.thread({
            await(*parked, 1u);
            unparkOne!PM(k, proto, (ref const LockedKey!PM lk, UnparkResult r) => UnparkDecision(1));
        });
    });
}

// ---------------------------------------------------------------------------
// SYK1: an installed parker is used inside and not after.

@("sync.parker.SYK1.installAndRestore")
@safe nothrow @nogc
unittest
{
    static immutable ParkerVtbl!NativePlatform vt;
    int ctx;
    auto previous = installParker(Parker!NativePlatform(&vt, null));
    assert(effectiveParker!NativePlatform().vtbl is &vt);
    pin();
    assert(effectiveParker!NativePlatform().vtbl !is &vt, "pinned: the thread parker");
    assert(effectiveParker!NativePlatform(1).vtbl is &vt, "a condition wait discounts its pin");
    unpin();
    installParker(previous);
    assert(effectiveParker!NativePlatform().vtbl !is &vt);
}

// ---------------------------------------------------------------------------
// Native (oracle 3).

@("sync.native.parkUnparkAcrossThreads")
@system unittest
{
    import core.atomic : atomicLoad, atomicOp;

    shared int word;
    const k = cast(size_t) &word;
    shared int woken;
    Thread[] ts;
    foreach (i; 0 .. 8)
        ts ~= new Thread({
            const r = park!NativePlatform(k, ParkOptions(proto), (ref const LockedKey!NativePlatform lk)
                => atomicLoad(word) == 0);
            assert(r.outcome == ParkOutcome.unparked || r.outcome == ParkOutcome.invalid);
            atomicOp!"+="(woken, 1);
        }).start();
    Thread.sleep(5.msecs);
    atomicOp!"+="(word, 1);
    uint total;
    while (atomicLoad(woken) < 8)
    {
        total += unparkAll!NativePlatform(k, proto, (ref const LockedKey!NativePlatform lk, UnparkResult r)
            => UnparkDecision(1)).unparked;
        Thread.sleep(1.msecs);
    }
    foreach (t; ts)
        t.join();
    assert(total <= 8);
}

@("sync.native.unparkAllBeyondOneRound")
@system unittest
{
    import core.atomic : atomicLoad, atomicOp;

    // More waiters than one delivery round (64): every one is woken once.
    enum n = 100;
    shared int queued, woken;
    shared int word;
    const k = cast(size_t) &word;
    Thread[] ts;
    foreach (i; 0 .. n)
        ts ~= new Thread({
            const r = park!NativePlatform(k, ParkOptions(proto), (ref const LockedKey!NativePlatform lk) {
                atomicOp!"+="(queued, 1);
                return true;
            });
            assert(r.outcome == ParkOutcome.unparked && r.token == 3);
            atomicOp!"+="(woken, 1);
        }, 64 * 1024).start();
    while (atomicLoad(queued) < n)
        Thread.sleep(1.msecs);
    const u = unparkAll!NativePlatform(k, proto, (ref const LockedKey!NativePlatform lk, UnparkResult r) {
        assert(r.unparked == n && !r.haveMore);
        return UnparkDecision(3);
    });
    assert(u.unparked == n);
    foreach (t; ts)
        t.join();
    assert(atomicLoad(woken) == n);
}

@("sync.native.timedParkTimesOut")
@system unittest
{
    import core.time : MonoTime;

    shared int word;
    const k = cast(size_t) &word;
    const start = MonoTime.currTime;
    const r = park!NativePlatform(k, ParkOptions(proto, deadline: Deadline.at(start + 3.msecs)),
        (ref const LockedKey!NativePlatform lk) => true);
    assert(r.outcome == ParkOutcome.timedOut);
    assert(MonoTime.currTime - start >= 3.msecs);
}
