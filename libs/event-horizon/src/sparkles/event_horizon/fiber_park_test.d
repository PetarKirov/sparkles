/**
Native tests of the fiber parker's inbox path
([fiber-parker.md](../../../../../docs/specs/event-horizon/fiber-parker.md),
§Testing): `sparkles.base.sync` primitives waited on by fibers and woken from
the same worker, another worker, a blocking-pool thread and a thread no
scheduler knows; deadlines, cancellation, `protect` and shields; the pinned
suspension check; the parker a callback sees; the wake inbox's order.

A waiting fiber must leave its worker free: each test that waits keeps a
second fiber running on the same worker and checks that it ran.
*/
module sparkles.event_horizon.fiber_park_test;

version (unittest):
version (Posix):

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread.osthread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.typecons : No;

import sparkles.base.sync : Condition, installParker, ManualResetEvent, Mutex,
    NativePlatform, Parker, Semaphore, WaitStatus;
import sparkles.event_horizon.cause : CancelContext, FiberContext, Interrupt,
    InterruptKind, cancelTree, interruptFiber;
import sparkles.event_horizon.fiber_park : fiberParker;
import sparkles.event_horizon.group : LoopGroup, LoopGroupConfig, RootScope, Topology;
import sparkles.event_horizon.errors : IoError, skipReason;
import sparkles.event_horizon.loop : LoopConfig;
import sparkles.event_horizon.sched : Alarm, currentScheduler, FiberPark, Sched, SchedOptions,
    schedOrSkip;
import sparkles.event_horizon.scope_ : checkCancellation, protect, withScope;
import sparkles.test_runner.skip : skipTest;

private:

/// Both paths, so that each scenario runs on each (fiber-parker.md EFP6): the
/// ring path falls back to the inbox where the kernel lacks the futex
/// operations.
immutable FiberPark[2] parkPaths = [FiberPark.ring, FiberPark.inbox];

/// Yields the current fiber until `cond` holds, failing if it never does.
void yieldUntil(ref Sched s, scope bool delegate() cond) @system
{
    const until = MonoTime.currTime + 10.seconds;
    while (!cond())
    {
        assert(MonoTime.currTime < until, "the awaited condition never held");
        s.yieldNow();
    }
}

/// Spawns a fiber on `s` that yields until `done`, counting its turns, and
/// returns the counter: a waiting fiber that blocked its worker would leave
/// it unchanged.
shared(uint)* spawnTicker(ref Sched s, shared(bool)* done) @system
{
    auto ticks = new shared uint;
    auto sp = &s;
    assert(!s.spawn(() {
        while (!atomicLoad(*done))
        {
            atomicOp!"+="(*ticks, 1);
            sp.yieldNow();
        }
    }).hasError);
    return ticks;
}

/// A bound on a wait the test expects to be woken: if the parker blocked the
/// worker instead, the wait times out and the test fails rather than hangs.
MonoTime bound() @safe nothrow @nogc => MonoTime.currTime + 2.seconds;

/// Fails unless a wait begun at `start` ended well before `bound()`: a wait
/// that a lost wake left to its deadline ends at the bound, and its result
/// alone would not tell.
void assertPrompt(MonoTime start) @safe nothrow @nogc
{
    assert(MonoTime.currTime - start < 1.seconds, "the wake was lost; the wait ran to its bound");
}

/// Starts a thread no scheduler knows, running `fn`.
Thread foreign(void delegate() fn) @system
{
    auto t = new Thread(fn);
    t.start();
    return t;
}

// ── wakes from every kind of waker (EFP7, EFP9, EFP12) ──────────────────────

@("fiberPark.semaphore.sameWorkerReleaseResumesTheWaiter")
@system
unittest
{
    foreach (path; parkPaths)
    {
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        Semaphore sem;
        int[] order;
        WaitStatus st;
        auto r = s.run(() {
            assert(!s.spawn(() {
                order ~= 1;
                st = sem.acquireUntil(bound());
                order ~= 3;
            }).hasError);
            assert(!s.spawn(() {
                order ~= 2;
                sem.release();
            }).hasError);
        });
        assert(!r.hasError);
        assert(st == WaitStatus.ok);
        assert(order == [1, 2, 3], "the waiter parked, and its worker ran the releaser");
        assert(sem.available == 0);
    }
}

@("fiberPark.semaphore.unregisteredThreadWakesTheWaiterOnItsOwner")
@system
unittest
{
    foreach (path; parkPaths)
    {
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        Semaphore sem;
        shared bool done;
        Thread owner, resumedOn;
        uint ticksWhileWaiting;
        auto r = s.run(() {
            owner = Thread.getThis();
            auto ticks = spawnTicker(s, &done);
            auto waker = foreign(() {
                Thread.sleep(20.msecs);
                sem.release();
            });
            const t0 = MonoTime.currTime;
            assert(sem.acquireUntil(bound()) == WaitStatus.ok);
            assertPrompt(t0);
            resumedOn = Thread.getThis();
            ticksWhileWaiting = atomicLoad(*ticks);
            atomicStore(done, true);
            waker.join();
        });
        assert(!r.hasError);
        assert(resumedOn is owner, "the fiber resumed on its owner's thread");
        assert(ticksWhileWaiting > 0, "the worker kept running while the fiber waited");
    }
}

@("fiberPark.mutex.otherWorkersHolderHandsTheLockToAFiber")
@system
unittest
{
    foreach (path; parkPaths)
    {
        {
            Sched probe;
            schedOrSkip(probe, SchedOptions(fiberPark: path));
            probe.destroy();
        }
        LoopGroup group;
        LoopGroupConfig cfg;
        cfg.topology = Topology.threadPerCore;
        cfg.workers = 2;
        cfg.pinToCpu = No.pinToCpu;
        cfg.fiberPark = path;
        auto started = LoopGroup.start(group, cfg);
        if (started.hasError)
            skipTest(skipReason(started.error));

        Mutex m;
        shared bool held, waiting, done;
        shared uint ticksWhileWaiting;
        shared bool gotIt;
        group.runEach((uint id, ref RootScope root, ref env) {
            auto s = &currentScheduler();
            if (id == 1)
            {
                // The holder blocks its own worker, as a pinned fiber may.
                m.lock();
                atomicStore(held, true);
                while (!atomicLoad(waiting))
                    Thread.sleep(1.msecs);
                Thread.sleep(20.msecs);
                m.unlock();
                return;
            }
            while (!atomicLoad(held))
                s.yieldNow();
            auto ticks = spawnTicker(*s, &done);
            atomicStore(waiting, true);
            const t0 = MonoTime.currTime;
            assert(m.lockUntil(bound()));
            atomicStore(ticksWhileWaiting, atomicLoad(*ticks));
            atomicStore(gotIt, true);
            m.unlock();
            atomicStore(done, true);
            assertPrompt(t0); // after the unlock: a failure must not leave the lock pinned
        });
        assert(atomicLoad(gotIt));
        assert(atomicLoad(ticksWhileWaiting) > 0, "the waiter's worker kept running");
    }
}

@("fiberPark.mutex.blockingPoolThreadHandsTheLockToAFiber")
@system
unittest
{
    foreach (path; parkPaths)
    {
        import sparkles.event_horizon.blocking_pool : BlockingPool;

        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead
        BlockingPool pool;
        assert(!BlockingPool.create(pool, workers: 1).hasError);
        scope (exit) cast(void) pool.shutdown();

        static struct Shared
        {
            Mutex m;
            shared bool held, waiting;
        }

        Shared sh;
        bool gotIt, jobOk;
        auto r = s.run(() {
            assert(!s.spawn(() {
                jobOk = !pool.run(s, (void* p) nothrow {
                    auto x = cast(Shared*) p;
                    x.m.lock();
                    atomicStore(x.held, true);
                    while (!atomicLoad(x.waiting))
                        Thread.sleep(1.msecs);
                    Thread.sleep(20.msecs);
                    x.m.unlock();
                }, &sh).hasError;
            }).hasError);
            yieldUntil(s, () => atomicLoad(sh.held));
            atomicStore(sh.waiting, true);
            const t0 = MonoTime.currTime;
            assert(sh.m.lockUntil(bound()));
            gotIt = true;
            sh.m.unlock();
            assertPrompt(t0); // after the unlock: a failure must not leave the lock pinned
        });
        assert(!r.hasError);
        assert(jobOk && gotIt);
    }
}

@("fiberPark.condition.notifiedFromAnotherThread")
@system
unittest
{
    foreach (path; parkPaths)
    {
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        Mutex m;
        Condition cond;
        bool ready;
        shared bool done;
        uint ticksWhileWaiting;
        auto r = s.run(() {
            auto ticks = spawnTicker(s, &done);
            auto notifier = foreign(() {
                Thread.sleep(20.msecs);
                auto g = m.guard();
                ready = true;
                cond.notifyOne();
            });
            const t0 = MonoTime.currTime;
            bool notified = true;
            {
                auto g = m.guard();
                while (!ready && notified)
                    notified = cond.waitUntil(g, bound()) || ready;
            }
            // Outside the guard: an `Error` need not run its destructor.
            assert(notified, "never notified");
            assertPrompt(t0);
            ticksWhileWaiting = atomicLoad(*ticks);
            atomicStore(done, true);
            notifier.join();
        });
        assert(!r.hasError);
        assert(ready);
        assert(ticksWhileWaiting > 0, "the worker kept running while the fiber waited");
    }
}

@("fiberPark.event.oneSetWakesMoreFibersThanACommitRound")
@system
unittest
{
    foreach (path; parkPaths)
    {
        // More waiters than one round of commits (64): the set wakes them in
        // rounds, and some waiters find themselves dequeued before their commit.
        enum n = 150;
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        ManualResetEvent ev;
        uint woken;
        auto r = s.run(() {
            foreach (_; 0 .. n)
                assert(!s.spawn(() {
                    if (ev.waitUntil(bound()) == WaitStatus.ok)
                        ++woken;
                }).hasError);
            yieldUntil(s, () => s.lotSleepers == n);
            auto setter = foreign(() { ev.set(); });
            yieldUntil(s, () => woken == n);
            setter.join();
        });
        assert(!r.hasError);
        assert(woken == n);
    }
}

// ── deadlines and cancellation (EFP5, EFP14, EFP16–EFP18) ───────────────────

@("fiberPark.deadline.timesOutWhileTheWorkerRuns")
@system
unittest
{
    foreach (path; parkPaths)
    {
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        Semaphore sem;
        shared bool done;
        WaitStatus st;
        uint ticksWhileWaiting;
        auto elapsed = MonoTime.zero - MonoTime.zero;
        auto r = s.run(() {
            auto ticks = spawnTicker(s, &done);
            const t0 = MonoTime.currTime;
            st = sem.acquireUntil(t0 + 20.msecs);
            elapsed = MonoTime.currTime - t0;
            ticksWhileWaiting = atomicLoad(*ticks);
            atomicStore(done, true);
        });
        assert(!r.hasError);
        assert(st == WaitStatus.timedOut);
        assert(elapsed >= 20.msecs);
        assert(ticksWhileWaiting > 0);
        assert(sem.available == 0);
    }
}

@("fiberPark.cancel.scopeCancelEndsEveryInterruptibleWaitAndStaysLatched")
@system
unittest
{
    foreach (path; parkPaths)
    {
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        Semaphore sem;
        Mutex m;
        ManualResetEvent ev;
        WaitStatus[3] first, second;
        bool[3] lockedAndWaited;
        auto r = s.run(() {
            cast(void) withScope!((ref sc) {
                foreach (i; 0 .. 3)
                    sc.spawn(((size_t i) => () {
                        first[i] = sem.acquireUntil(MonoTime.max, true);
                        // Sticky (EFP16): the latch ends the next wait at once.
                        second[i] = sem.acquireUntil(bound(), true);
                        // Waits that are not interruptible still complete.
                        m.lock();
                        m.unlock();
                        ev.wait();
                        lockedAndWaited[i] = true;
                    })(i));
                yieldUntil(s, () => s.lotSleepers == 3);
                sc.cancel();
                ev.set();
            })(s);
        });
        assert(!r.hasError);
        foreach (i; 0 .. 3)
        {
            assert(first[i] == WaitStatus.cancelled);
            assert(second[i] == WaitStatus.cancelled);
            assert(lockedAndWaited[i]);
        }
    }
}

@("fiberPark.cancel.directInterruptEndsOnlyThatFiber")
@system
unittest
{
    foreach (path; parkPaths)
    {
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        Semaphore sem;
        FiberContext* victim;
        WaitStatus victimSt = WaitStatus.ok, otherSt = WaitStatus.cancelled;
        auto r = s.run(() {
            cast(void) withScope!((ref sc) {
                sc.spawn(() {
                    victim = s.currentContext();
                    victimSt = sem.acquireUntil(MonoTime.max, true);
                });
                sc.spawn(() { otherSt = sem.acquireUntil(MonoTime.max, true); });
                yieldUntil(s, () => s.lotSleepers == 2);
                interruptFiber(victim, Interrupt(InterruptKind.cancelled));
                yieldUntil(s, () => s.lotSleepers == 1);
                sem.release();
            })(s);
        });
        assert(!r.hasError);
        assert(victimSt == WaitStatus.cancelled);
        assert(otherSt == WaitStatus.ok);
    }
}

@("fiberPark.protect.interruptibleWaitSleepsThroughACancellation")
@system
unittest
{
    foreach (path; parkPaths)
    {
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        Semaphore sem;
        WaitStatus inside = WaitStatus.cancelled;
        bool cancelledAfter;
        auto r = s.run(() {
            cast(void) withScope!((ref sc) {
                sc.spawn(() {
                    cast(void) protect!(() {
                        inside = sem.acquireUntil(MonoTime.max, true);
                        return 0;
                    })(s);
                    cancelledAfter = checkCancellation(s).hasError;
                });
                yieldUntil(s, () => s.lotSleepers == 1);
                sc.cancel();
                s.yieldNow();
                assert(s.lotSleepers == 1, "a protected wait is not cancelled");
                sem.release();
            })(s);
        });
        assert(!r.hasError);
        assert(inside == WaitStatus.ok);
        assert(cancelledAfter, "the latched interrupt lands after the shield");
    }
}

@("fiberPark.shield.childSurvivesTheScopesCancellationUntilItsOwnerEndsIt")
@system
unittest
{
    foreach (path; parkPaths)
    {
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        Semaphore sem;
        CancelContext shield;
        shield.isProtected = true;
        WaitStatus st = WaitStatus.ok;
        bool survivedTheSweep;
        auto r = s.run(() {
            cast(void) withScope!((ref sc) {
                sc.node.addChild(&shield);
                assert(sc.spawnShielded(() {
                    st = sem.acquireUntil(MonoTime.max, true);
                }, &shield));
                yieldUntil(s, () => s.lotSleepers == 1);
                sc.cancel();
                s.yieldNow();
                survivedTheSweep = s.lotSleepers == 1;
                cancelTree(&shield, Interrupt(InterruptKind.cancelled));
            })(s);
        });
        assert(!r.hasError);
        assert(survivedTheSweep, "the scope's sweep stopped at the shield");
        assert(st == WaitStatus.cancelled, "the owner's cancellation ended the wait");
    }
}

// ── pinning (EFP20) ─────────────────────────────────────────────────────────

@("fiberPark.pinned.suspensionWhileHoldingAMutexAsserts")
@system
unittest
{
    foreach (path; parkPaths)
    {
        import core.exception : AssertError;

        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        Mutex m;
        bool asserted;
        FiberContext* self;
        auto r = s.run(() {
            self = s.currentContext();
            // Wakes the park should it ever suspend, so a missing check fails
            // the assertion below instead of hanging.
            assert(!s.spawn(() {
                if (!asserted)
                    s.wake(self);
            }).hasError);
            m.lock();
            try
                s.park();
            catch (AssertError)
                asserted = true;
            m.unlock();
        });
        assert(!r.hasError);
        assert(asserted, "a pinned fiber's suspension fails its assertion");
    }
}

// ── the parker each context sees (EFP1) ─────────────────────────────────────

/// The calling thread's current parker.
Parker!NativePlatform currentParker() @system nothrow @nogc
{
    auto p = installParker(Parker!NativePlatform.init);
    cast(void) installParker(p);
    return p;
}

@("fiberPark.parker.aFiberAndALoopCallbackEachSeeTheirOwn")
@system
unittest
{
    foreach (path; parkPaths)
    {
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead

        static struct Seen
        {
            bool fiberOwn, callbackThread, fired;
        }

        Seen seen;
        Alarm alarm;
        Semaphore sem;
        auto r = s.run(() {
            auto t = Sched.tryCurrent();
            const mine = currentParker();
            seen.fiberOwn = mine.vtbl is fiberParker(t).vtbl && mine.ctx is cast(void*) t;
            s.armCallbackAlarm(alarm, MonoTime.currTime, (void* p) nothrow @nogc {
                auto x = cast(Seen*) p;
                x.callbackThread = !currentParker();
                x.fired = true;
            }, &seen);
            cast(void) sem.acquireUntil(MonoTime.currTime + 20.msecs);
        });
        assert(!r.hasError);
        assert(seen.fiberOwn, "a fiber sees its own fiber parker");
        assert(seen.fired && seen.callbackThread, "a loop callback sees the thread parker");
    }
}

// ── the wake inbox (EFP13) ──────────────────────────────────────────────────

@("fiberPark.inbox.drainsInTheOrderThePushesLanded")
@system
unittest
{
    Sched s;
    schedOrSkip(s, SchedOptions(fiberPark: FiberPark.inbox));
    scope (success) s.destroy(); // a failed run is abandoned instead

    Semaphore[3] sems;
    int[] order;
    auto r = s.run(() {
        foreach (i; 0 .. 3)
            assert(!s.spawn(((int i) => () {
                if (sems[i].acquireUntil(bound()) == WaitStatus.ok)
                    order ~= i;
            })(i)).hasError);
        yieldUntil(s, () => s.lotSleepers == 3);
        // The worker is held here while the thread pushes all three, so one
        // drain sees them together.
        auto t = foreign(() {
            sems[1].release();
            sems[2].release();
            sems[0].release();
        });
        t.join();
        yieldUntil(s, () => order.length == 3);
    });
    assert(!r.hasError);
    assert(order == [1, 2, 0], "resumed in push order");
}

// ── a defect that strands parked fibers (EFP21) ─────────────────────────────

noreturn exitWith42(in IoError) nothrow @nogc @trusted
{
    import core.sys.posix.unistd : _exit;

    _exit(42);
}

@("fiberPark.abandon.childBody")
@system
unittest
{
    import std.process : environment;

    // The body of the test below: a no-op in the ordinary run, the abandoned
    // run when spawned by it. Nothing here returns on that path.
    if (environment.get("EH_ABANDON_CHILD", "") == "")
        return;

    LoopConfig cfg;
    cfg.fatalHook = &exitWith42;
    Semaphore sem;
    {
        Sched s;
        assert(!Sched.create(s, SchedOptions(), cfg).hasError);
        cast(void) s.run(() {
            assert(!s.spawn(() { cast(void) sem.acquireUntil(MonoTime.max); }).hasError);
            yieldUntil(s, () => s.lotSleepers == 1);
            assert(false, "the defect");
        });
    }
    assert(0, "the abandoned run must end the process");
}

@("fiberPark.abandon.aFiberParkedOnBaseSyncEndsTheProcessAfterTheDefect")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : thisExePath;
    import std.process : execute;

    // Subprocess, never in-process: the teardown ends the process. The
    // parked fiber's record and every later wake would name the scheduler
    // the defect unwound, so the run cannot be leaked; the defect is still
    // reported first.
    const r = execute([thisExePath, "-i", `fiberPark\.abandon\.childBody`, "-t", "1"],
        ["EH_ABANDON_CHILD": "1"]);
    assert(r.status == 42, r.output);
    assert(r.output.canFind("with 1 fiber(s) parked"), r.output);
    assert(r.output.canFind("the defect: the defect at "), r.output);
}

// ── the ring path (EFP6–EFP8, EFP22) ────────────────────────────────────────

@("fiberPark.ring.aParkWaitsInTheKernelOnlyOnTheRingPath")
@system
unittest
{
    // EFP6: `ring` waits in the kernel, `inbox` does not, on one kernel.
    foreach (path; parkPaths)
    {
        Sched s;
        schedOrSkip(s, SchedOptions(fiberPark: path));
        scope (success) s.destroy(); // a failed run is abandoned instead
        if (path == FiberPark.ring && !s.ringPark)
            skipTest("the ring path needs the futex operations (Linux 6.7)");
        assert(s.ringPark == (path == FiberPark.ring));

        Semaphore sem;
        uint inFlightWhileParked;
        auto r = s.run(() {
            assert(!s.spawn(() {
                assert(sem.acquireUntil(bound()) == WaitStatus.ok);
            }).hasError);
            yieldUntil(s, () => s.lotSleepers == 1);
            if (path == FiberPark.ring)
                yieldUntil(s, () => s.loop.inFlight == 1);
            else
                foreach (_; 0 .. 4 * SchedOptions.init.resumeBudget)
                    s.yieldNow(); // several ticks, so several submission points
            inFlightWhileParked = s.loop.inFlight;
            sem.release();
        });
        assert(!r.hasError);
        assert(inFlightWhileParked == (path == FiberPark.ring ? 1 : 0),
            "a ring park is one wait in the kernel, an inbox park none");
        assert((s.loop.heldSubmitted > 0) == (path == FiberPark.ring));
    }
}

@("fiberPark.ring.aSameTickHandoffSubmitsNothing")
@system
unittest
{
    // EFP8: the waiter parks and is released by a fiber on its worker before
    // the tick's submission point, so its wait is never written.
    Sched s;
    schedOrSkip(s, SchedOptions(fiberPark: FiberPark.ring));
    scope (success) s.destroy(); // a failed run is abandoned instead
    if (!s.ringPark)
        skipTest("the ring path needs the futex operations (Linux 6.7)");

    Semaphore sem;
    bool got;
    auto r = s.run(() {
        assert(!s.spawn(() {
            got = sem.acquireUntil(bound()) == WaitStatus.ok;
        }).hasError);
        s.yieldNow(); // the waiter runs and parks; this fiber is next in the tick
        assert(s.lotSleepers == 1);
        sem.release();
    });
    assert(!r.hasError);
    assert(got);
    assert(s.loop.heldSubmitted == 0, "the handoff reached the kernel");
}

@("fiberPark.ring.fewerThanTwoSubmissionEntriesFailToStart")
@system
unittest
{
    import sparkles.event_horizon.loop : LoopConfig;

    // EFP22: a wait and its linked timeout need two entries.
    LoopConfig cfg;
    cfg.backend.sqEntries = 1;
    Sched s;
    assert(Sched.create(s, SchedOptions(fiberPark: FiberPark.ring), cfg).hasError);

    LoopGroup group;
    LoopGroupConfig gcfg;
    gcfg.sqEntries = 1;
    gcfg.fiberPark = FiberPark.ring;
    assert(LoopGroup.start(group, gcfg).hasError);
}

@("fiberPark.ring.aStrayWakeWritesTheWaitAgain")
@system
unittest
{
    import sparkles.base.sync.seam : WakeCount;
    import sparkles.event_horizon.sched : FiberTask;

    // EFP3, EFP7: the kernel matches wakes by address, so a wake meant for
    // an earlier park can end this one's wait while its word still sleeps.
    // The fiber stays parked, the wait is written again, and the real
    // delivery then resumes it once.
    Sched s;
    schedOrSkip(s, SchedOptions(fiberPark: FiberPark.ring));
    scope (success) s.destroy(); // a failed run is abandoned instead
    if (!s.ringPark)
        skipTest("the ring path needs the futex operations (Linux 6.7)");

    Semaphore sem;
    FiberTask waiter;
    uint resumed, writtenBeforeStray, inFlightAfterStray;
    auto r = s.run(() {
        assert(!s.spawn(() {
            waiter = Sched.tryCurrent();
            assert(sem.acquireUntil(bound()) == WaitStatus.ok);
            ++resumed;
        }).hasError);
        yieldUntil(s, () => s.loop.inFlight == 1);
        writtenBeforeStray = s.loop.heldSubmitted;
        NativePlatform.seamWake(waiter.park.word, WakeCount.all);
        yieldUntil(s, () => s.loop.heldSubmitted == writtenBeforeStray + 1);
        inFlightAfterStray = s.loop.inFlight;
        assert(resumed == 0, "a stray wake resumed the fiber");
        sem.release();
        yieldUntil(s, () => resumed == 1);
    });
    assert(!r.hasError);
    assert(inFlightAfterStray == 1, "the wait was written again");
    assert(resumed == 1);
}

@("fiberPark.ring.aForeignWakeBeforeTheSubmissionPointSubmitsNothing")
@system
unittest
{
    // EFP8: a thread no scheduler knows wins the sleep before the tick's
    // submission point, which then finds the word resolved and resumes the
    // fiber without writing its wait.
    Sched s;
    schedOrSkip(s, SchedOptions(fiberPark: FiberPark.ring));
    scope (success) s.destroy(); // a failed run is abandoned instead
    if (!s.ringPark)
        skipTest("the ring path needs the futex operations (Linux 6.7)");

    Semaphore sem;
    bool got;
    auto r = s.run(() {
        assert(!s.spawn(() {
            got = sem.acquireUntil(bound()) == WaitStatus.ok;
        }).hasError);
        s.yieldNow(); // the waiter parks; this fiber runs on in the same tick
        assert(s.lotSleepers == 1);
        foreign(() { sem.release(); }).join();
    });
    assert(!r.hasError);
    assert(got);
    assert(s.loop.heldSubmitted == 0, "the resolved sleep's wait was written");
}
