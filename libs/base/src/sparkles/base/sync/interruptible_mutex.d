/**
The interruptible mutex (primitives.md §4): a lock for critical sections that
may suspend, which a cancelled fiber stops waiting for without ever being
left holding it.

Acquisition returns a guard, and only the guard's destruction releases it
(SYJ1). Waiters are granted the mutex in queue order by direct handoff
whenever any are parked (SYJ5); a handoff committed before a cancellation
wins its arbitration keeps the lock for the waiter (SYJ3). Holding it does
not pin the caller (SYJ4).
*/
module sparkles.base.sync.interruptible_mutex;

import core.time : MonoTime;

import sparkles.base.sync.parker : observesCancellation;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.protocol;
import sparkles.base.sync.seam : Deadline;

/// How a waiting operation ended (SYI5): results, not exceptions.
enum WaitStatus : ubyte
{
    ok,
    timedOut,
    /// A try form found the lock held (SYJ6).
    unavailable,
    cancelled,
}

private enum ubyte locked = 1, parked = 2;

/// The interruptible mutex for platform `P`.
struct InterruptibleMutexT(P)
{
    package(sparkles.base.sync) P.Atomic!ubyte state;

    @disable this(this);

    /// Locks, waiting interruptibly (SYJ2): a guard, or cancellation with nothing held.
    Acquisition!P lock() shared @safe nothrow @nogc => acquire(Deadline.never, true);

    /// Locks by `deadline`, interruptibly (SYJ2).
    Acquisition!P lockUntil(MonoTime deadline) shared @safe nothrow @nogc
        => acquire(Deadline.at(deadline), true);

    /// Locks if free and nobody is queued, without waiting (SYJ6).
    Acquisition!P tryLock() shared @trusted nothrow @nogc
    {
        ubyte e = 0;
        if (P.cas!(Order.acquire, Order.relaxed)(state, e, locked))
            return Acquisition!P(InterruptibleGuard!P(&this), WaitStatus.ok);
        return Acquisition!P(InterruptibleGuard!P.init, WaitStatus.unavailable);
    }

    Acquisition!P lock() @safe nothrow @nogc => sh.lock();
    Acquisition!P lockUntil(MonoTime deadline) @safe nothrow @nogc => sh.lockUntil(deadline);
    Acquisition!P tryLock() @safe nothrow @nogc => sh.tryLock();

    /// Acquisition by a deadline in platform ticks (the model's virtual clock).
    package(sparkles.base.sync) Acquisition!P acquire(Deadline d, bool interruptible) shared @trusted nothrow @nogc
    {
        const s = acquireRaw(d, interruptible);
        return Acquisition!P(s == WaitStatus.ok ? InterruptibleGuard!P(&this) : InterruptibleGuard!P.init, s);
    }

    package(sparkles.base.sync) Acquisition!P acquire(Deadline d, bool interruptible) @safe nothrow @nogc
        => sh.acquire(d, interruptible);

    /**
    Acquires without a guard. `Condition` reacquires through this, never
    interruptibly (SYJ1, SYC3); nothing else may.
    */
    package(sparkles.base.sync) WaitStatus acquireRaw(Deadline d, bool interruptible) shared @safe nothrow @nogc
    {
        ubyte e = 0;
        if (P.cas!(Order.acquire, Order.relaxed)(state, e, locked))
            return WaitStatus.ok;
        return acquireSlow(d, interruptible);
    }

    private WaitStatus acquireSlow(Deadline d, bool interruptible) shared @safe nothrow @nogc
    {
        const key = keyOf();
        while (true)
        {
            bool acquired;
            const r = park!P(key, ParkOptions(Protocol.interruptibleMutex, deadline: d,
                    interruptible: observesCancellation!P(interruptible)),
                (ref const LockedKey!P lk) {
                    ubyte cur = P.load!(Order.relaxed)(state);
                    while (true)
                    {
                        if (!(cur & locked))
                        {
                            // Free (nobody can be queued: every release with
                            // waiters hands off): take it under the lock.
                            if (P.cas!(Order.acquire, Order.relaxed)(state, cur, cast(ubyte)(cur | locked)))
                            {
                                acquired = true;
                                return false;
                            }
                            continue;
                        }
                        const ns = cast(ubyte)(cur | parked);
                        if (ns == cur || P.cas!(Order.relaxed, Order.relaxed)(state, cur, ns))
                            return true;
                    }
                },
                null,
                (ref const LockedKey!P lk, bool haveMore) {
                    if (!haveMore)
                        clear(parked);
                    return false;
                });
            final switch (r.outcome)
            {
            case ParkOutcome.invalid:
                if (acquired)
                    return WaitStatus.ok;
                continue;
            case ParkOutcome.unparked:
                // A handoff committed before any cancellation won (SYJ3).
                assert(r.token == tokenHandoff, "an interruptible mutex waiter woken with a foreign token");
                return WaitStatus.ok;
            case ParkOutcome.timedOut:
                return WaitStatus.timedOut;
            case ParkOutcome.cancelled:
                return WaitStatus.cancelled;
            }
        }
    }

    /// Releases: hands the mutex to the head of the queue if anyone is parked (SYJ5).
    package(sparkles.base.sync) void release() shared @safe nothrow @nogc
    {
        ubyte e = locked;
        if (P.cas!(Order.release, Order.relaxed)(state, e, cast(ubyte) 0))
            return;
        assert(e & locked, "release of an interruptible mutex that is not held");
        unparkOne!P(keyOf(), Protocol.interruptibleMutex,
            (ref const LockedKey!P lk, UnparkResult res) {
                if (res.unparked)
                {
                    // The mutex stays held; the park's return carries the
                    // release edge (SYH1, SYH2).
                    if (!res.haveMore)
                        clear(parked);
                    return UnparkDecision(tokenHandoff);
                }
                ubyte cur = P.load!(Order.relaxed)(state);
                while (!P.cas!(Order.release, Order.relaxed)(state, cur, cast(ubyte) 0)) {}
                return UnparkDecision(0);
            });
    }

    // For `Condition`.

    /// Under both buckets' locks: if held, mark parked (SYC5).
    package(sparkles.base.sync) bool markParkedIfHeld() shared @safe nothrow @nogc
    {
        ubyte cur = P.load!(Order.relaxed)(state);
        while (cur & locked)
            if (P.cas!(Order.relaxed, Order.relaxed)(state, cur, cast(ubyte)(cur | parked)))
                return true;
        return false;
    }

    /// Under both buckets' locks: acquire a free mutex for a woken waiter (SYC6).
    package(sparkles.base.sync) bool acquireFor() shared @safe nothrow @nogc
    {
        ubyte cur = P.load!(Order.relaxed)(state);
        while (!(cur & locked))
            if (P.cas!(Order.acquire, Order.relaxed)(state, cur, cast(ubyte)(cur | locked)))
                return true;
        return false;
    }

    package(sparkles.base.sync) void markParked() shared @safe nothrow @nogc
    {
        ubyte cur = P.load!(Order.relaxed)(state);
        while (!P.cas!(Order.relaxed, Order.relaxed)(state, cur, cast(ubyte)(cur | parked))) {}
    }

    package(sparkles.base.sync) size_t keyOf() shared @trusted nothrow @nogc => cast(size_t) &state;

    private void clear(ubyte bits) shared @safe nothrow @nogc
    {
        ubyte cur = P.load!(Order.relaxed)(state);
        while (!P.cas!(Order.relaxed, Order.relaxed)(state, cur, cast(ubyte)(cur & ~bits))) {}
    }

    private ref shared(InterruptibleMutexT) sh() return @trusted nothrow @nogc
        => *cast(shared(InterruptibleMutexT)*) &this;
}

/// The interruptible mutex (primitives.md §4).
alias InterruptibleMutex = InterruptibleMutexT!NativePlatform;

/// Holds an `InterruptibleMutex`; its destruction is the only release (SYJ1).
struct InterruptibleGuard(P)
{
    private shared(InterruptibleMutexT!P)* mutex;

    @disable this(this);

    /// Only an acquisition makes one, holding the mutex (SYJ1).
    package(sparkles.base.sync) this(shared(InterruptibleMutexT!P)* m) @safe nothrow @nogc
    {
        mutex = m;
    }

    ~this() @safe nothrow @nogc
    {
        if (mutex !is null)
            mutex.release();
    }

    /// Whether this guard holds the mutex.
    bool holds() const @safe nothrow @nogc => mutex !is null;

    package(sparkles.base.sync) shared(InterruptibleMutexT!P)* lock() @safe nothrow @nogc => mutex;
}

/// An acquisition's result: a guard on success, and how the wait ended (SYI5).
struct Acquisition(P)
{
    InterruptibleGuard!P guard;
    WaitStatus status;

    /// Whether the mutex was acquired: an empty guard is never a success.
    bool opCast(T : bool)() const @safe nothrow @nogc => status == WaitStatus.ok && guard.holds;
}

static assert(InterruptibleMutex.sizeof == 1);
static assert(!__traits(hasMember, InterruptibleMutex, "unlock"), "SYJ1: no raw unlock");
