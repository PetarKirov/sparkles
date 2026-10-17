/**
The mutex, and the same lock embedded in three bits of a caller's word
(primitives.md §2, §3).

The lock has three bits: locked, parked (waiters may be queued) and
designated (a woken waiter is on its way). An unlock that finds a designated
waker pending wakes nobody (SYM6), and the lock is free for a running locker
to take (SYM7); a waiter that keeps losing to such lockers asks to be handed
the lock and parks at the head of the queue (SYM8). `Mutex` is the lock over
one byte; `LockBits` projects it onto bits of any atomic integer, leaving
the other bits alone (SYL1, SYL2).

Holding either pins the caller (SYK9): it is a non-interruptible lock, for
short critical sections that never suspend.
*/
module sparkles.base.sync.mutex;

import core.time : MonoTime;

import sparkles.base.sync.parker : effectiveParker, pin, unpin;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.protocol;
import sparkles.base.sync.seam : Deadline;

/// `relax` steps a locker spins before parking under `P` (SYM9).
package(sparkles.base.sync) enum uint lockSpinFor(P) = P.isModel ? 1 : spinSteps;

/**
The lock algorithm over the bits `L`, `PK` and `D` of a word of type `T`,
for platform `P`. `whole` says the word holds nothing else, so the
uncontended paths compare against constants (SYM2).
*/
package(sparkles.base.sync) struct LockBitsT(P, T, T L, T PK, T D, bool whole = false)
{
    static assert(L && PK && D && !(L & PK) && !(L & D) && !(PK & D),
        "LockBits needs three distinct bits");

    private enum T lockMask = cast(T)(L | PK | D);

static:
    /// One compare-and-swap: free with no waiters to locked (SYM2).
    pragma(inline, true) bool acquireFast(A)(ref A word)
    {
        static if (whole)
            T s = 0;
        else
            T s = cast(T)(P.load!(Order.relaxed)(word) & ~lockMask);
        return P.cas!(Order.acquire, Order.relaxed)(word, s, cast(T)(s | L));
    }

    /// One compare-and-swap: locked with no waiters to free (SYM2).
    pragma(inline, true) bool releaseFast(A)(ref A word)
    {
        static if (whole)
            T s = L;
        else
            T s = cast(T)((P.load!(Order.relaxed)(word) & ~lockMask) | L);
        return releaseCas(word, s, cast(T)(s & ~L));
    }

    void lock(A)(ref A word)
    {
        if (!acquireFast(word))
            cast(void) lockSlow(word, Deadline.never, false);
        pin!P();
    }

    bool lockUntil(A)(ref A word, Deadline d)
    {
        if (!acquireFast(word) && !lockSlow(word, d, false))
            return false;
        pin!P();
        return true;
    }

    /// Without parking, spinning or the parking lot (SYM4).
    bool tryLock(A)(ref A word)
    {
        T s = P.load!(Order.relaxed)(word);
        while (!(s & L))
            if (P.cas!(Order.acquire, Order.relaxed)(word, s, cast(T)(s | L)))
            {
                pin!P();
                return true;
            }
        return false;
    }

    void unlock(A)(ref A word)
    {
        if (!releaseFast(word))
            unlockSlow(word);
        unpin!P();
    }

    /// A release compare-and-swap; the model's seeded fault weakens it (oracle 1, 4).
    private bool releaseCas(A)(ref A word, ref T expected, T desired)
    {
        static if (P.isModel)
            if (P.faultActive(P.Fault.releaseRelaxed))
                return P.cas!(Order.relaxed, Order.relaxed)(word, expected, desired);
        return P.cas!(Order.release, Order.relaxed)(word, expected, desired);
    }

    private bool faultNoHandoff()()
    {
        static if (P.isModel)
            return P.faultActive(P.Fault.noHandoff);
        else
            return false;
    }

    private bool faultWakeDespiteDesignation()()
    {
        static if (P.isModel)
            return P.faultActive(P.Fault.wakeDespiteDesignation);
        else
            return false;
    }

    /// Clears `bits` under the bucket lock with a CAS loop; returns the new value.
    private T clearBits(A)(ref A word, T bits)
    {
        T cur = P.load!(Order.relaxed)(word);
        while (!P.cas!(Order.relaxed, Order.relaxed)(word, cur, cast(T)(cur & ~bits))) {}
        return cast(T)(cur & ~bits);
    }

    /**
    The contended acquisition: spin while nobody is parked, then park. With
    `designated`, the caller is already the designated waker, as a condition
    waiter woken through the lock's queue is (SYC2).
    */
    bool lockSlow(A)(ref A word, Deadline d, bool designated)
    {
        const key = cast(size_t) &word;
        uint spin, lost;
        // An escaping Error must not leave a designation behind (SYM6).
        scope (failure)
            if (designated)
                passOn(word);
        while (true)
        {
            T s = P.load!(Order.relaxed)(word);
            if (!(s & L))
            {
                T ns = cast(T)(s | L);
                if (designated)
                    ns &= ~D;
                if (P.cas!(Order.acquire, Order.relaxed)(word, s, ns))
                {
                    if (designated)
                        retire!P(key);
                    return true;
                }
                continue;
            }
            if (!d.isNever && d.passed(P.now()))
            {
                if (designated)
                    passOn(word);
                return false;
            }
            // Spin only while nobody is parked and no designated waker is
            // pending (SYM9).
            if (spin < lockSpinFor!P && !(s & (PK | D)))
            {
                auto eff = effectiveParker!P();
                eff.vtbl.relax(eff.ctx, spin++);
                continue;
            }
            // A designated waker that parks again has lost a race (SYM8).
            if (designated)
                ++lost;
            const handoff = lost >= starvationBoundFor!P && !faultNoHandoff();
            bool acquired;
            const r = park!P(key, ParkOptions(Protocol.mutex,
                    parkToken: handoff ? parkHandoffRequest : 0, deadline: d, atHead: handoff),
                (ref const LockedKey!P lk) {
                    T cur = P.load!(Order.relaxed)(word);
                    while (true)
                    {
                        if (!(cur & L))
                        {
                            // Free: take it here, under the bucket lock, as one
                            // read–modify–write. A validation that only declined
                            // would let a locker alternate forever between a failed
                            // CAS and an invalid park, never woken and so never
                            // promoted (SYM8; oracle 10 finding F1).
                            T ns = cast(T)(cur | L);
                            if (designated)
                                ns &= ~D;
                            if (P.cas!(Order.acquire, Order.relaxed)(word, cur, ns))
                            {
                                acquired = true;
                                return false;
                            }
                            continue;
                        }
                        T ns = cast(T)(cur | PK);
                        // The caller's own designation ends as it parks; a
                        // designation with no registration behind it is stale (SYP15).
                        if (designated || ((cur & D) && !lk.hasRegistration))
                            ns &= ~D;
                        if (ns == cur || P.cas!(Order.relaxed, Order.relaxed)(word, cur, ns))
                            return true;
                    }
                },
                null,
                (ref const LockedKey!P lk, bool haveMore) {
                    if (!haveMore)
                        cast(void) clearBits(word, PK);
                });
            final switch (r.outcome)
            {
            case ParkOutcome.invalid:
                if (acquired)
                {
                    if (designated)
                        retire!P(key);
                    return true;
                }
                if (designated)
                    --lost;
                continue;
            case ParkOutcome.unparked:
                // Parking ended any earlier designation.
                designated = false;
                if (r.token == tokenHandoff)
                    return true; // the mutex was handed over, held (SYM8)
                assert(r.token == tokenDesignated, "a mutex waiter woken with a foreign token");
                designated = true;
                spin = 0;
                continue;
            case ParkOutcome.timedOut:
                return false;
            case ParkOutcome.cancelled:
                assert(0, "a mutex wait is not interruptible");
            }
        }
    }

    /**
    A designated waker gives up without the lock (SYM6): its registration is
    retired, its designation ends, and if the lock is free with waiters
    parked, one of them becomes the designated waker. A held lock's next
    unlock wakes one instead.
    */
    private void passOn(A)(ref A word)
    {
        const key = cast(size_t) &word;
        unparkOne!P(key, Protocol.mutex,
            (ref const LockedKey!P lk, UnparkResult res) {
                if (res.unparked == 0)
                {
                    if (!res.haveMore)
                        cast(void) clearBits(word, PK);
                    return UnparkDecision(0);
                }
                T cur = P.load!(Order.relaxed)(word);
                while (true)
                {
                    T ns = cast(T)(cur | D);
                    if (!res.haveMore)
                        ns &= ~PK;
                    if (P.cas!(Order.relaxed, Order.relaxed)(word, cur, ns))
                        break;
                }
                return UnparkDecision(tokenDesignated, designate: true);
            },
            true, 0,
            (ref const LockedKey!P lk) {
                const cur = clearBits(word, D);
                return !(cur & L) && (cur & PK);
            });
    }

    /// The contended release: wake the head of the queue, or release without a wake.
    void unlockSlow(A)(ref A word)
    {
        while (true)
        {
            T s = P.load!(Order.relaxed)(word);
            assert(s & L, "unlock of a mutex that is not held (SYM5)");
            // Nobody parked, or a designated waker on its way: release, so a
            // running locker may barge (SYM6, SYM7).
            if ((s & PK) && (!(s & D) || faultWakeDespiteDesignation()))
                break;
            if (releaseCas(word, s, cast(T)(s & ~L)))
                return;
        }
        const key = cast(size_t) &word;
        unparkOne!P(key, Protocol.mutex,
            (ref const LockedKey!P lk, UnparkResult res) {
                if (res.unparked == 0)
                {
                    // Declined for a pending designated waker, or nobody queued
                    // (a stale parked bit, reconciled: SYP15).
                    T cur = P.load!(Order.relaxed)(word);
                    T clear = res.haveMore ? L : cast(T)(L | PK);
                    while (!releaseCas(word, cur, cast(T)(cur & ~clear))) {}
                    return UnparkDecision(0);
                }
                if (res.firstParkToken == parkHandoffRequest && !faultNoHandoff())
                {
                    // Hand the mutex over: it stays held, and the park's return
                    // carries the release edge (SYH1, SYH2).
                    if (!res.haveMore)
                        cast(void) clearBits(word, PK);
                    return UnparkDecision(tokenHandoff);
                }
                assert(!lk.hasRegistration, "two designated wakers (SYM6)");
                T cur = P.load!(Order.relaxed)(word);
                while (true)
                {
                    T ns = cast(T)((cur & ~L) | D);
                    if (!res.haveMore)
                        ns &= ~PK;
                    if (releaseCas(word, cur, ns))
                        break;
                }
                return UnparkDecision(tokenDesignated, designate: true);
            },
            false, 0,
            (ref const LockedKey!P lk) {
                // Decline while a designated waker is on its way, unless the
                // head asked to be handed the lock (SYM6, SYM8).
                const cur = P.load!(Order.relaxed)(word);
                if (!(cur & D) || faultWakeDespiteDesignation())
                    return true;
                if (!lk.hasRegistration)
                {
                    cast(void) clearBits(word, D); // stale (SYP15)
                    return true;
                }
                return lk.headParkToken == parkHandoffRequest && !faultNoHandoff();
            });
    }

    // For `Condition` (§6): wait morphing onto this lock.

    /// Under both buckets' locks: if held, mark parked and report true (SYC5).
    bool markParkedIfHeld(A)(ref A word)
    {
        T cur = P.load!(Order.relaxed)(word);
        while (cur & L)
            if (P.cas!(Order.relaxed, Order.relaxed)(word, cur, cast(T)(cur | PK)))
                return true;
        return false;
    }

    /// Under the bucket lock: mark parked, for waiters moved onto a free lock (SYC6).
    void markParked(A)(ref A word)
    {
        T cur = P.load!(Order.relaxed)(word);
        while (!P.cas!(Order.relaxed, Order.relaxed)(word, cur, cast(T)(cur | PK))) {}
    }

    /// After a condition wait's wake through this lock's queue (SYC2).
    void relockAfterWake(A)(ref A word, size_t token)
    {
        if (token == tokenHandoff)
            return pin!P();
        if (token == tokenDesignated)
        {
            cast(void) lockSlow(word, Deadline.never, true);
            return pin!P();
        }
        lock(word);
    }
}

/// `starvationBound` under `P`: the model uses 2, so the handoff is reachable.
package(sparkles.base.sync) enum uint starvationBoundFor(P) = P.isModel ? 2 : starvationBound;

// ---------------------------------------------------------------------------
// The public types.

/**
A lock embedded in three caller-chosen bits of a caller-owned atomic integer
of 1, 2, 4 or 8 bytes (SYL1), keyed by the integer's address. Every operation
changes only its three bits (SYL2). A word carries at most one embedded lock
and is not also used with the address wait (SYL3).
*/
struct LockBits(T, T locked, T parked, T designated)
    if (is(T == ubyte) || is(T == ushort) || is(T == uint) || is(T == ulong))
{
    package(sparkles.base.sync) alias Impl = LockBitsT!(NativePlatform, T, locked, parked, designated);

static:
    /// Locks, parking while held.
    void lock(ref shared T word) @safe nothrow @nogc => Impl.lock(word);

    /// Locks by `deadline`; `false` holding nothing (SYM3).
    bool lockUntil(ref shared T word, MonoTime deadline) @safe nothrow @nogc
        => Impl.lockUntil(word, Deadline.at(deadline));

    /// Locks if free, without waiting (SYM4).
    bool tryLock(ref shared T word) @safe nothrow @nogc => Impl.tryLock(word);

    /// Releases the lock the caller holds (SYM5).
    void unlock(ref shared T word) @safe nothrow @nogc => Impl.unlock(word);

    /// Locks and returns a guard that unlocks when destroyed.
    Guard guard(return ref shared T word) @trusted nothrow @nogc
    {
        Impl.lock(word);
        return Guard(&word);
    }

    /// Holds the lock; unlocks on destruction.
    struct Guard
    {
        private shared(T)* word;

        package(sparkles.base.sync) alias Impl = LockBits.Impl;
        package(sparkles.base.sync) alias Word = T;
        package(sparkles.base.sync) enum T lockedBit = locked, parkedBit = parked;

        @disable this(this);

        ~this() @safe nothrow @nogc
        {
            if (word !is null)
                Impl.unlock(*word);
        }

        package(sparkles.base.sync) ref shared(T) lockWord() return @trusted nothrow @nogc => *word;
    }
}

/**
A one-byte, non-recursive mutex that records no owner (SYM1, SYM5). Its
`.init` is unlocked (SYA6); it cannot be copied (SYA4), and its address is
its identity, so it is never moved while held or waited on (SYA5).
*/
struct MutexT(P)
{
    package(sparkles.base.sync) P.Atomic!ubyte state;

    package(sparkles.base.sync) alias Impl = LockBitsT!(P, ubyte, 1, 2, 4, true);

    @disable this(this);

    /// Locks, parking while held (SYM3).
    void lock() shared @safe nothrow @nogc => Impl.lock(state);
    /// Locks by `deadline`; `false` holding nothing (SYM3).
    bool lockUntil(MonoTime deadline) shared @safe nothrow @nogc
        => Impl.lockUntil(state, Deadline.at(deadline));
    /// Locks if free, without waiting (SYM4).
    bool tryLock() shared @safe nothrow @nogc => Impl.tryLock(state);
    /// Releases the mutex the caller holds (SYM5).
    void unlock() shared @safe nothrow @nogc => Impl.unlock(state);
    /// Locks and returns a guard that unlocks when destroyed.
    MutexGuard!P guard() shared return @trusted nothrow @nogc
    {
        lock();
        return MutexGuard!P(&this);
    }

    /// Locks by a deadline in the platform's ticks (the model's virtual clock).
    package(sparkles.base.sync) bool lockUntilTicks(Deadline d) shared @safe nothrow @nogc
        => Impl.lockUntil(state, d);

    package(sparkles.base.sync) ref shared(P.Atomic!ubyte) word() shared return @safe nothrow @nogc => state;

    // The same operations on an unshared mutex, such as a `__gshared` one.
    void lock() @safe nothrow @nogc => sh.lock();
    bool lockUntil(MonoTime deadline) @safe nothrow @nogc => sh.lockUntil(deadline);
    bool tryLock() @safe nothrow @nogc => sh.tryLock();
    void unlock() @safe nothrow @nogc => sh.unlock();
    MutexGuard!P guard() return @safe nothrow @nogc => sh.guard();
    package(sparkles.base.sync) bool lockUntilTicks(Deadline d) @safe nothrow @nogc => sh.lockUntilTicks(d);

    private ref shared(MutexT) sh() return @trusted nothrow @nogc => *cast(shared(MutexT)*) &this;
}

/// The mutex (primitives.md §3).
alias Mutex = MutexT!NativePlatform;

/// Holds a mutex; unlocks on destruction.
struct MutexGuard(P)
{
    private shared(MutexT!P)* mutex;

    @disable this(this);

    ~this() @safe nothrow @nogc
    {
        if (mutex !is null)
            mutex.unlock();
    }

    /// The mutex this guard holds, for `Condition`.
    package(sparkles.base.sync) shared(MutexT!P)* lock() @safe nothrow @nogc => mutex;
}

static assert(Mutex.sizeof == 1, "SYM1");
static assert(!__traits(compiles, { Mutex a; Mutex b = a; }), "SYA4");
