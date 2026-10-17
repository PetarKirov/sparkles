/**
Native tests of the process lifecycle and allocation: `fork` (SYX1), thread
exit (SYX2) and the allocation audit (oracle 7, SYA1).
*/
module sparkles.base.sync.lifecycle_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : MonoTime, msecs;

import sparkles.base.sync;
import sparkles.base.sync.parking_lot : bucketIndex, LockedKey, unparkOne, UnparkDecision, UnparkResult;
import sparkles.base.sync.protocol : Protocol;

private __gshared Mutex forkHeld;
private __gshared Mutex[64] forkCandidates;
private shared bool forkChildDone;

/// A mutex among `forkCandidates` that shares `m`'s bucket, if any.
private Mutex* sameBucket(ref Mutex m) @trusted
{
    foreach (ref c; forkCandidates)
        if (&c !is &m && bucketIndex(cast(size_t) &c) == bucketIndex(cast(size_t) &m))
            return &c;
    return null;
}

version (Posix)
@("sync.native.SYX1.forkChildRecovers")
@system unittest
{
    import core.sys.posix.sys.wait : waitpid, WEXITSTATUS, WIFEXITED;
    import core.sys.posix.unistd : _exit, fork;

    // The parent holds a mutex with waiters parked behind it, while other
    // threads hammer the bucket the mutex hashes to.
    forkHeld.lock();
    shared bool stop;
    shared int parked;
    Thread[] ts;
    foreach (_; 0 .. 2)
        ts ~= new Thread({
            atomicOp!"+="(parked, 1);
            forkHeld.lock();
            forkHeld.unlock();
        }).start();
    // A thread keeps the bucket's own lock busy through the parking lot, so
    // the fork may land while it holds it; no primitive it touches is held
    // across the fork (a held one stays held in the child, by SYX1).
    auto neighbour = sameBucket(forkHeld);
    const bucketKey = cast(size_t) &forkHeld;
    ts ~= new Thread({
        while (!atomicLoad(stop))
            unparkOne!NativePlatform(bucketKey, Protocol.mutex,
                (ref const LockedKey!NativePlatform lk, UnparkResult r) => UnparkDecision(0),
                false, 0, (ref const LockedKey!NativePlatform lk) => false);
    }).start();
    while (atomicLoad(parked) < 2)
        Thread.sleep(1.msecs);
    Thread.sleep(2.msecs);

    const pid = fork();
    if (pid == 0)
    {
        // The child: the mutex the parent held is still held, and only this
        // thread exists. It must unlock it, take it again from a new thread,
        // and use the neighbour, without hanging on a stale bucket or bit.
        forkHeld.unlock();
        if (neighbour !is null)
        {
            neighbour.lock();
            neighbour.unlock();
        }
        // Only async-fork-safe work from here: another test thread of the
        // parent may have held the GC's lock at the fork, so the child
        // creates its thread with pthread_create and allocates nothing.
        import core.sys.posix.pthread : pthread_create, pthread_join, pthread_t;
        import core.sys.posix.time : nanosleep, timespec;

        forkHeld.lock();
        static extern (C) void* contender(void*) nothrow @nogc
        {
            forkHeld.lock();
            atomicStore(forkChildDone, true);
            forkHeld.unlock();
            return null;
        }
        pthread_t t;
        if (pthread_create(&t, null, &contender, null) != 0)
            _exit(4);
        auto nap = timespec(0, 1_000_000);
        nanosleep(&nap, null);
        forkHeld.unlock(); // wakes the child's own waiter
        pthread_join(t, null);
        _exit(atomicLoad(forkChildDone) ? 0 : 3);
    }
    assert(pid > 0, "fork failed");
    forkHeld.unlock();
    atomicStore(stop, true);
    foreach (t; ts)
        t.join();
    int status;
    // A hang in the child is the failure mode: bound it.
    const deadline = MonoTime.currTime + 10_000.msecs;
    import core.sys.posix.sys.wait : WNOHANG;
    while (waitpid(pid, &status, WNOHANG) == 0)
    {
        assert(MonoTime.currTime < deadline, "the forked child hung on a primitive (SYX1)");
        Thread.sleep(1.msecs);
    }
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0, "the forked child could not recover");
}

@("sync.native.SYX2.threadExitWithAWakeInFlight")
@system unittest
{
    // Threads park, are woken, and exit at once; deliveries may still be in
    // flight to their freed thread-local words (SYK8). The parent then keeps
    // using the same mutex.
    __gshared Mutex m;
    foreach (round; 0 .. 50)
    {
        m.lock();
        Thread[] ts;
        foreach (_; 0 .. 4)
            ts ~= new Thread({ m.lock(); m.unlock(); }).start();
        Thread.sleep(0.msecs);
        m.unlock();
        foreach (t; ts)
            t.join();
    }
    assert(m.tryLock());
    m.unlock();
}

version (VfsAllocationAudit)
version (linux)
@("sync.allocation.SYA1.noLibcOrGcAllocation")
@system unittest
{
    import core.memory : GC;
    import sparkles.base.vfs.allocation_audit : allocationCalls, auditActive;

    __gshared Mutex m;
    __gshared Condition c;
    __gshared InterruptibleMutex im;
    __gshared Once once;
    __gshared int shared_;
    shared bool stop;

    // Helpers on other threads keep the primitives contended; only this
    // thread's allocations are counted.
    Thread[] ts;
    foreach (_; 0 .. 3)
        ts ~= new Thread({
            while (!atomicLoad(stop))
            {
                m.lock();
                ++shared_;
                c.notifyAll();
                m.unlock();
                auto a = im.lock();
            }
        }).start();

    static void exercise() @system
    {
        foreach (k; 0 .. 2_000)
        {
            {
                auto g = m.guard();
                ++shared_;
                if (k % 16 == 0)
                    cast(void) c.waitUntil(g, MonoTime.currTime + 1.msecs);
            }
            if (m.lockUntil(MonoTime.currTime + 1.msecs))
                m.unlock();
            {
                auto a = im.lockUntil(MonoTime.currTime + 1.msecs);
            }
            once.call(() {});
        }
    }

    exercise();
    const gcBefore = GC.allocatedInCurrentThread();
    allocationCalls = 0;
    auditActive = true;
    exercise();
    auditActive = false;
    atomicStore(stop, true);
    foreach (t; ts)
        t.join();
    assert(allocationCalls == 0, "a sync operation called a libc allocator (SYA1)");
    assert(GC.allocatedInCurrentThread() == gcBefore, "a sync operation allocated on the GC heap (SYA1)");
}
