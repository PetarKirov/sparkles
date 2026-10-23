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
import sparkles.event_horizon.sched : Alarm, currentScheduler, Sched, SchedOptions, schedOrSkip;
import sparkles.event_horizon.scope_ : checkCancellation, protect, withScope;
import sparkles.test_runner.skip : skipTest;

private:

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
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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

@("fiberPark.semaphore.unregisteredThreadWakesTheWaiterOnItsOwner")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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
        assert(sem.acquireUntil(bound()) == WaitStatus.ok);
        resumedOn = Thread.getThis();
        ticksWhileWaiting = atomicLoad(*ticks);
        atomicStore(done, true);
        waker.join();
    });
    assert(!r.hasError);
    assert(resumedOn is owner, "the fiber resumed on its owner's thread");
    assert(ticksWhileWaiting > 0, "the worker kept running while the fiber waited");
}

@("fiberPark.mutex.otherWorkersHolderHandsTheLockToAFiber")
@system
unittest
{
    {
        Sched probe;
        schedOrSkip(probe);
        probe.destroy();
    }
    LoopGroup group;
    LoopGroupConfig cfg;
    cfg.topology = Topology.threadPerCore;
    cfg.workers = 2;
    cfg.pinToCpu = No.pinToCpu;
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
        assert(m.lockUntil(bound()));
        atomicStore(ticksWhileWaiting, atomicLoad(*ticks));
        atomicStore(gotIt, true);
        m.unlock();
        atomicStore(done, true);
    });
    assert(atomicLoad(gotIt));
    assert(atomicLoad(ticksWhileWaiting) > 0, "the waiter's worker kept running");
}

@("fiberPark.mutex.blockingPoolThreadHandsTheLockToAFiber")
@system
unittest
{
    import sparkles.event_horizon.blocking_pool : BlockingPool;

    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();
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
        assert(sh.m.lockUntil(bound()));
        gotIt = true;
        sh.m.unlock();
    });
    assert(!r.hasError);
    assert(jobOk && gotIt);
}

@("fiberPark.condition.notifiedFromAnotherThread")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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
        {
            auto g = m.guard();
            while (!ready)
                if (!cond.waitUntil(g, bound()))
                    assert(ready, "never notified");
        }
        ticksWhileWaiting = atomicLoad(*ticks);
        atomicStore(done, true);
        notifier.join();
    });
    assert(!r.hasError);
    assert(ready);
    assert(ticksWhileWaiting > 0, "the worker kept running while the fiber waited");
}

@("fiberPark.event.oneSetWakesMoreFibersThanACommitRound")
@system
unittest
{
    // More waiters than one round of commits (64): the set wakes them in
    // rounds, and some waiters find themselves dequeued before their commit.
    enum n = 150;
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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

// ── deadlines and cancellation (EFP5, EFP14, EFP16–EFP18) ───────────────────

@("fiberPark.deadline.timesOutWhileTheWorkerRuns")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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

@("fiberPark.cancel.scopeCancelEndsEveryInterruptibleWaitAndStaysLatched")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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

@("fiberPark.cancel.directInterruptEndsOnlyThatFiber")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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

@("fiberPark.protect.interruptibleWaitSleepsThroughACancellation")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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

@("fiberPark.shield.childSurvivesTheScopesCancellationUntilItsOwnerEndsIt")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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

// ── pinning (EFP20) ─────────────────────────────────────────────────────────

@("fiberPark.pinned.suspensionWhileHoldingAMutexAsserts")
@system
unittest
{
    import core.exception : AssertError;

    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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

// ── the wake inbox (EFP13) ──────────────────────────────────────────────────

@("fiberPark.inbox.drainsInTheOrderThePushesLanded")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

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
